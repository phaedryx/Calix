//
//  SessionInfoContractTests.swift
//  CalixTests
//
//  Contract test for `SessionInfo`/`SessionLifecycleState`
//  (SessionDaemonClient.swift's hand-mirror of Rust's
//  `proto::SessionInfo`/`proto::SessionState`, see
//  calix-session/crates/proto/src/control.rs) against a REAL
//  `calix-session` daemon + CLI round trip.
//
//  Why this exists alongside SessionInfoTests.swift: that file proves
//  Swift's decoder accepts JSON someone hand-typed to already match the
//  Swift struct's own shape -- it can never fail from a Rust-side
//  rename, since nothing there is actually derived from Rust. A silent
//  field rename or tag change in control.rs's `#[derive(Serialize)]`
//  sails through every one of those assertions untouched. This test
//  decodes whatever bytes THIS run's real `calix-session ls --all
//  --json` printed, straight from a real daemon it spawns itself -- so
//  a Rust-side rename fails HERE, not silently at runtime in the
//  shipped app.
//
//  Spawns a real daemon (`calix-session daemon --foreground`) against
//  a scratch --runtime-dir/--state-dir under a temp directory (never
//  touches the real ~/.calix), creates one real session via `new`,
//  and decodes the real `ls --all --json` stdout with Swift's own
//  SessionInfo/SessionLifecycleState types -- the exact same types
//  SessionDaemonClient.listAll()/sessionState(id:) decode in
//  production.
//
//  FAILS (does not skip) when build/session/calix-session hasn't been
//  built locally (scripts/build-session.sh). Skipping was considered
//  and rejected: this test exists specifically to catch a Rust-side
//  rename, and a rename lands in control.rs, not in this binary --
//  someone who changes control.rs and runs the Swift suite without
//  rebuilding Rust first is exactly the person this test must not stay
//  silently green for. "Not built" is a local/CI setup gap, not an
//  unsupported configuration, given the Rust sources are right here in
//  the repo.
//

import XCTest
@testable import Calix

final class SessionInfoContractTests: XCTestCase {

    private var daemonProcess: Process?
    private var scratchDir: String!

    override func setUp() {
        super.setUp()
        // `/tmp` directly (not `FileManager.default.temporaryDirectory`,
        // which resolves to a much longer per-app `/var/folders/.../T/`
        // path on macOS) and an 8-char suffix (not a full UUID): the
        // daemon binds a real `AF_UNIX` socket at
        // `<runtimeDir>/sessiond.sock`, and `sockaddr_un.sun_path` caps
        // out around 104 bytes on Darwin -- a `temporaryDirectory` +
        // full-UUID scratch dir overflows that and fails with "path
        // must be shorter than SUN_LEN" (confirmed empirically).
        scratchDir = "/tmp/cxc-\(UUID().uuidString.prefix(8))"
    }

    override func tearDown() {
        if let daemonProcess, daemonProcess.isRunning {
            daemonProcess.terminate()
            daemonProcess.waitUntilExit()
        }
        daemonProcess = nil
        if let scratchDir {
            try? FileManager.default.removeItem(atPath: scratchDir)
        }
        scratchDir = nil
        super.tearDown()
    }

    // MARK: - Binary resolution

    /// `<repo root>/build/session/calix-session`, produced by
    /// `scripts/build-session.sh` -- resolved relative to THIS test
    /// file's own path (`#filePath`), three directories below the repo
    /// root (`CalixTests/Sessions/<this file>.swift`), rather than any
    /// bundled app resource: this test wants the freshly-built Rust
    /// binary on disk, not whatever `Calix.app` happened to bundle at
    /// its own last build. `CALIX_SESSION_BIN` overrides, mirroring
    /// `SessionBinaryResolver`'s own production env-override precedent.
    private func resolveRealBinaryPath() -> String? {
        if let override = ProcessInfo.processInfo.environment["CALIX_SESSION_BIN"], !override.isEmpty {
            return FileManager.default.isExecutableFile(atPath: override) ? override : nil
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../CalixTests/Sessions
            .deletingLastPathComponent() // .../CalixTests
            .deletingLastPathComponent() // repo root
        let candidate = repoRoot.appendingPathComponent("build/session/calix-session").path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    // MARK: - Process helpers

    @discardableResult
    private func runCLI(_ binaryPath: String, _ args: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    /// `--foreground` keeps the daemon as a directly-controllable child
    /// process this test can `terminate()` in `tearDown()` -- the
    /// default double-forking path detaches into a grandchild `Process`
    /// loses its handle to entirely. `stderr` is piped (not
    /// `/dev/null`) so a startup failure (e.g. socket bind error) is
    /// diagnosable from the retry loop's own failure message below,
    /// rather than surfacing only as an opaque "never became reachable."
    private func startDaemon(binaryPath: String, runtimeDir: String, stateDir: String) throws -> (process: Process, stderr: Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["--runtime-dir", runtimeDir, "--state-dir", stateDir, "daemon", "--foreground"]
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        return (process, stderrPipe)
    }

    // MARK: - Contract test

    func test_realDaemonSessionInfo_decodesWithSwiftMirrorTypes() throws {
        guard let binaryPath = resolveRealBinaryPath() else {
            XCTFail(
                "build/session/calix-session not found -- this contract test requires it. " +
                "Run scripts/build-session.sh (or set CALIX_SESSION_BIN) before running CalixTests. " +
                "This is a hard failure, not a skip: silently passing without the real Rust binary " +
                "would defeat this test's entire purpose (catching a Rust-side schema rename)."
            )
            return
        }

        let runtimeDir = scratchDir + "/run"
        let stateDir = scratchDir + "/state"
        try FileManager.default.createDirectory(atPath: scratchDir, withIntermediateDirectories: true)

        let (daemon, daemonStderr) = try startDaemon(binaryPath: binaryPath, runtimeDir: runtimeDir, stateDir: stateDir)
        daemonProcess = daemon

        // `new` requires the daemon already listening -- unlike
        // `attach`, it never auto-starts one (see new.rs's own doc
        // comment) -- so retry briefly instead of guessing a fixed
        // startup delay. `--argv /bin/cat` gives a deterministic,
        // config-free child that just blocks reading stdin forever
        // (unlike the daemon default of the user's real login shell,
        // which would load their actual shell config here).
        var created: (exitCode: Int32, stdout: String, stderr: String)?
        for _ in 0..<50 {
            guard daemon.isRunning else { break }
            let result = try runCLI(binaryPath, [
                "--runtime-dir", runtimeDir, "--state-dir", stateDir,
                "new", "--name", "contract-test-session", "--argv", "/bin/cat",
            ])
            if result.exitCode == 0 {
                created = result
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let newResult = created else {
            let stderrData = daemonStderr.fileHandleForReading.availableData
            let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
            XCTFail(
                "calix-session daemon never became reachable for `new` within 5s " +
                "(daemon running: \(daemon.isRunning)); daemon stderr: \(stderrText)"
            )
            return
        }
        let sessionID = newResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(sessionID.isEmpty, "`new` must print the created session's id on stdout")

        let lsResult = try runCLI(binaryPath, [
            "--runtime-dir", runtimeDir, "--state-dir", stateDir, "ls", "--all", "--json",
        ])
        XCTAssertEqual(lsResult.exitCode, 0, "ls --all --json failed: \(lsResult.stderr)")

        // The actual contract check: Swift's own SessionInfo/
        // SessionLifecycleState decoder against REAL stdout from a REAL
        // daemon -- not a hand-typed literal (contrast SessionInfoTests.swift).
        let sessions = try JSONDecoder().decode([SessionInfo].self, from: Data(lsResult.stdout.utf8))

        let running = try XCTUnwrap(
            sessions.first { $0.id == sessionID },
            "the just-created session id must appear in `ls --all --json`'s real output; got ids=\(sessions.map(\.id))"
        )
        XCTAssertEqual(running.name, "contract-test-session")
        XCTAssertEqual(running.state, .running)
        XCTAssertGreaterThan(running.pid, 0, "a Running session must report a real child pid")
        XCTAssertEqual(running.attachedClients, 0, "created via `new`, never attached")
        XCTAssertEqual(running.meta, [:])
        XCTAssertGreaterThan(running.createdAtMs, 0)

        // Kill it and confirm the SAME real round trip reflects
        // `.exited` -- the struct-variant CBOR-on-the-wire /
        // JSON-on-stdout shape `SessionLifecycleState`'s custom
        // `init(from:)` exists specifically to decode.
        let killResult = try runCLI(binaryPath, [
            "--runtime-dir", runtimeDir, "--state-dir", stateDir, "kill", sessionID,
        ])
        XCTAssertEqual(killResult.exitCode, 0, "kill failed: \(killResult.stderr)")

        let lsAfterKill = try runCLI(binaryPath, [
            "--runtime-dir", runtimeDir, "--state-dir", stateDir, "ls", "--all", "--json",
        ])
        let sessionsAfterKill = try JSONDecoder().decode([SessionInfo].self, from: Data(lsAfterKill.stdout.utf8))
        let exited = try XCTUnwrap(sessionsAfterKill.first { $0.id == sessionID })
        // 137 = 128 + SIGKILL(9): `kill` always signals SIGKILL
        // (conn.rs), and the daemon's own reap() reports an unavailable
        // `status.code()` (a signal death, not a normal exit) as
        // `128 + signal` -- pinning the exact value, not just the
        // `.exited` case, so a change to either convention is caught.
        XCTAssertEqual(exited.state, .exited(code: 137))
    }
}

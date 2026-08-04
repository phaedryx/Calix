// PaneCLIExec.swift
// CalixUITests
//
// Shared pane-command-injection helpers for the E2E suites added
// alongside SessionPersistenceE2ETests (E2E-1/E2E-2/E2E-3). Mirrors
// `BrowserScriptingUITests.terminalExec`'s already-established
// pattern (paste via Cmd+V, not `app.typeText`, so IME/global-keystroke
// synthesis concerns don't apply the same way typed text would) rather
// than inventing a new one; kept here instead of promoted onto
// `CalixUITestCase` itself or merged into `BrowserScriptingUITests`'s
// own private copy, since both of those files are outside this task's
// assigned scope.
//
// Rationale for pasting into a live pane at all, instead of spawning
// `calix-session` as an out-of-process `Process` from inside the test
// runner: `SessionPersistenceE2ETests.swift`'s header comment
// establishes that the `CalixUITests` runner is itself App-Sandboxed
// and cannot open a new unix-domain-socket connection to the daemon,
// so a `calix-session` child spawned directly by the runner can never
// reach it. Routing the same CLI calls through a real pane (an
// already-running, unsandboxed child process of Calix.app) is the
// same workaround `BrowserScriptingUITests` already uses for the
// `calix` CLI.
//
// CRITICAL, field-verified constraint (found running this suite, not
// assumed): a command pasted into a pane does NOT inherit Calix.app's
// own `HOME` override. Ghostty execs every surface's command via
// `login -flp <system-username> ...` (confirmed via `ps aux` on a live
// run), which resets the shell's environment against the REAL system
// user, independent of whatever `HOME` `app.launchEnvironment` set on
// Calix.app's own process. A bare `calix-session <subcommand>` typed
// into a pane therefore falls back to resolving `$HOME` fresh inside
// that reset shell -- the developer's REAL home, not this test's
// isolated one -- and silently operates against the real daemon
// instead. `SessionCommandSynthesizer.attachCommand`'s own doc comment
// (Calix/Features/Sessions/SessionCommandSynthesizer.swift:74-140)
// independently confirms this exact failure mode was already
// field-verified for Calix's OWN internal session commands, which is
// why that function no longer relies on an env override and instead
// bakes explicit `--runtime-dir`/`--state-dir` flags into the command
// string at Swift level before ghostty ever execs it. Every pane
// command this suite issues MUST do the same -- see
// `calixSessionRootFlags(homeDir:)` below -- never a bare
// `calix-session <subcommand>` with no flags.
import XCTest

extension CalixUITestCase {

    /// Path to a pre-built `calix-session` binary, resolved the same
    /// way `SessionPersistenceE2ETests` resolves it: from the
    /// `CALIX_SESSION_BIN` environment variable this test process
    /// itself was launched with (supplied by the `/e2e-test` skill
    /// invocation, or a `cargo build --release` step run ahead of the
    /// UI test bundle -- a test-runner-phase concern, not this file's).
    /// Read here (the TEST RUNNER's own environment) so a caller can
    /// interpolate it into a command pasted into a pane. Unlike the
    /// binary PATH itself (a fixed location, unaffected by which HOME
    /// resolves), the session ROOT a pane-executed command targets is
    /// NOT safe to leave implicit -- see this file's header and
    /// `calixSessionRootFlags(homeDir:)`.
    static var builtSessionBinaryPath: String {
        ProcessInfo.processInfo.environment["CALIX_SESSION_BIN"] ?? ""
    }

    /// `--runtime-dir <homeDir>/.calix/run --state-dir <homeDir>/.calix/
    /// state`, matching `SessionCommandSynthesizer.attachCommand`'s own
    /// composed paths exactly (`<root>/.calix/{run,state}`). MUST be
    /// appended to every `calix-session` invocation pasted into a pane
    /// (see this file's header) so it resolves against this test's own
    /// isolated `homeDir` regardless of what `login` resets the pane's
    /// shell environment to.
    func calixSessionRootFlags(homeDir: String) -> String {
        "--runtime-dir \(homeDir)/.calix/run --state-dir \(homeDir)/.calix/state"
    }

    /// Pastes `command` into the frontmost pane via Cmd+V (bypassing
    /// IME/typeText's global-keystroke-synthesis concerns, see this
    /// file's header) with its stdout+stderr redirected to a fresh
    /// `/tmp` file, presses Return, and polls that file until it has
    /// content (or a bounded number of attempts elapse), returning the
    /// trimmed content. Mirrors `BrowserScriptingUITests.terminalExec`
    /// exactly; kept as a near-duplicate rather than a shared call so
    /// neither file depends on the other.
    func paneExec(_ command: String, counter: inout Int, timeoutAttempts: Int = 20) -> String {
        counter += 1
        let outFile = "/tmp/calix-e2e-\(ProcessInfo.processInfo.processIdentifier)-\(counter).txt"
        try? FileManager.default.removeItem(atPath: outFile)

        Thread.sleep(forTimeInterval: 1)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("\(command) > \(outFile) 2>&1", forType: .string)
        app.typeKey("v", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(.return, modifierFlags: [])

        for _ in 0..<timeoutAttempts {
            Thread.sleep(forTimeInterval: 0.5)
            if FileManager.default.fileExists(atPath: outFile),
               let content = try? String(contentsOfFile: outFile, encoding: .utf8),
               !content.isEmpty {
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return (try? String(contentsOfFile: outFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "(no output)"
    }

    /// Pastes `command` into the frontmost pane and presses Return,
    /// like `paneExec`, but does NOT redirect output to a file or wait
    /// for one to appear -- for injecting a command whose own output
    /// this caller doesn't need to read back (e.g. a long-running
    /// foreground command used only to keep a pane "busy", or a
    /// fire-and-forget administrative command whose effect is verified
    /// through the daemon ledger instead). Unlike `paneExec`, this
    /// never blocks waiting on the command to produce output, so it is
    /// safe to use for a command that runs indefinitely.
    func panePasteAndReturn(_ command: String) {
        Thread.sleep(forTimeInterval: 1)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(command, forType: .string)
        app.typeKey("v", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(.return, modifierFlags: [])
    }
}

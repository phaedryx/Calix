import XCTest
@testable import Calix

final class BrowserSecurityTests: XCTestCase {

    // MARK: - Top-Level Scheme Filtering

    func test_allows_http_scheme_at_top_level() {
        XCTAssertTrue(BrowserSecurity.isAllowedTopLevelScheme("http"))
    }

    func test_allows_https_scheme_at_top_level() {
        XCTAssertTrue(BrowserSecurity.isAllowedTopLevelScheme("https"))
    }

    func test_allows_about_scheme_at_top_level() {
        XCTAssertTrue(BrowserSecurity.isAllowedTopLevelScheme("about"))
    }

    func test_blocks_javascript_scheme_at_top_level() {
        XCTAssertFalse(BrowserSecurity.isAllowedTopLevelScheme("javascript"))
    }

    func test_blocks_data_scheme_at_top_level() {
        XCTAssertFalse(BrowserSecurity.isAllowedTopLevelScheme("data"))
    }

    func test_blocks_file_scheme_at_top_level() {
        XCTAssertFalse(BrowserSecurity.isAllowedTopLevelScheme("file"))
    }

    func test_blocks_blob_scheme_at_top_level() {
        XCTAssertFalse(BrowserSecurity.isAllowedTopLevelScheme("blob"))
    }

    // MARK: - Subresource Scheme Filtering

    func test_allows_blob_scheme_for_subresources() {
        XCTAssertTrue(BrowserSecurity.isAllowedSubresourceScheme("blob"))
    }

    func test_blocks_javascript_scheme_for_subresources() {
        XCTAssertFalse(BrowserSecurity.isAllowedSubresourceScheme("javascript"))
    }

    func test_allows_https_scheme_for_subresources() {
        XCTAssertTrue(BrowserSecurity.isAllowedSubresourceScheme("https"))
    }

    // MARK: - Filename Sanitization

    func test_sanitize_strips_path_separators() {
        let result = BrowserSecurity.sanitizeFilename("../etc/passwd")
        XCTAssertFalse(result.contains("/"), "Sanitized filename must not contain path separators")
        XCTAssertFalse(result.contains(".."), "Sanitized filename must not contain traversal sequences")
    }

    func test_sanitize_strips_leading_dots() {
        let result = BrowserSecurity.sanitizeFilename(".hidden")
        XCTAssertFalse(result.hasPrefix("."), "Sanitized filename must not start with a dot")
    }

    func test_sanitize_rejects_double_dangerous_extensions() {
        let result = BrowserSecurity.sanitizeFilename("file.txt.exe")
        XCTAssertFalse(result.hasSuffix(".exe"), "Dangerous second extension must be stripped")
    }

    func test_sanitize_truncates_long_filenames() {
        let longName = String(repeating: "a", count: 300)
        let result = BrowserSecurity.sanitizeFilename(longName)
        XCTAssertLessThanOrEqual(result.count, 255)
    }

    func test_sanitize_defaults_empty_string_to_download() {
        let result = BrowserSecurity.sanitizeFilename("")
        XCTAssertEqual(result, "download")
    }

    // MARK: - MIME Rejection

    func test_blocks_msdownload_mime() {
        XCTAssertTrue(BrowserSecurity.isBlockedMIME("application/x-msdownload"))
    }

    func test_allows_text_plain_mime() {
        XCTAssertFalse(BrowserSecurity.isBlockedMIME("text/plain"))
    }

    func test_allows_octet_stream_mime() {
        XCTAssertFalse(BrowserSecurity.isBlockedMIME("application/octet-stream"))
    }

    // MARK: - Download Path Validation

    func test_validates_normal_path_under_allowed_directory() {
        let downloads = NSTemporaryDirectory() + "Downloads"
        let filePath = downloads + "/report.pdf"
        XCTAssertTrue(BrowserSecurity.validateDownloadPath(filePath, allowedDirectory: downloads))
    }

    func test_rejects_path_traversal() {
        let downloads = NSTemporaryDirectory() + "Downloads"
        let escapedPath = downloads + "/../etc/passwd"
        XCTAssertFalse(BrowserSecurity.validateDownloadPath(escapedPath, allowedDirectory: downloads))
    }

    func test_rejects_symlink_escape() throws {
        let tmpDir = NSTemporaryDirectory() + "calix_test_\(UUID().uuidString)"
        let allowedDir = tmpDir + "/allowed"
        let outsideDir = tmpDir + "/outside"
        let symlinkPath = allowedDir + "/escape"

        let fm = FileManager.default
        try fm.createDirectory(atPath: allowedDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: outsideDir, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: symlinkPath, withDestinationPath: outsideDir)

        addTeardownBlock {
            try? fm.removeItem(atPath: tmpDir)
        }

        let escapedPath = symlinkPath + "/secret.txt"
        XCTAssertFalse(BrowserSecurity.validateDownloadPath(escapedPath, allowedDirectory: allowedDir))
    }

    // MARK: - Constants

    func test_max_redirect_depth_is_ten() {
        XCTAssertEqual(BrowserSecurity.maxRedirectDepth, 10)
    }
}

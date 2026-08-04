import Foundation
import AppKit
import WebKit
import UniformTypeIdentifiers
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.calix.terminal",
    category: "DownloadManager"
)

@MainActor
class DownloadManager: NSObject, WKDownloadDelegate {
    private let downloadsDirectory: URL

    init(downloadsDirectory: URL? = nil) {
        self.downloadsDirectory = downloadsDirectory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        super.init()
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        // 1. Sanitize filename
        let sanitized = BrowserSecurity.sanitizeFilename(suggestedFilename)

        // 2. Check MIME type
        if let mimeType = response.mimeType, BrowserSecurity.isBlockedMIME(mimeType) {
            logger.warning("Blocked download with MIME type: \(mimeType)")
            return nil
        }

        // 3. Build destination path
        let destination = downloadsDirectory.appendingPathComponent(sanitized)

        // 4. Validate path
        if !BrowserSecurity.validateDownloadPath(destination.path, allowedDirectory: downloadsDirectory.path) {
            logger.error("Download path validation failed: \(destination.path)")
            return nil
        }

        return destination
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        logger.error("Download failed: \(error.localizedDescription)")
    }

    func downloadDidFinish(_ download: WKDownload) {
        logger.info("Download completed")
        // Set quarantine xattr
        if let url = download.progress.fileURL {
            setQuarantineAttribute(on: url)
        }
    }

    // MARK: - Quarantine

    private func setQuarantineAttribute(on fileURL: URL) {
        let quarantineProperties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "Calix",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload,
        ]
        do {
            try (fileURL as NSURL).setResourceValue(quarantineProperties, forKey: .quarantinePropertiesKey)
            logger.info("Quarantine attribute set on \(fileURL.lastPathComponent)")
        } catch {
            logger.error("Failed to set quarantine on \(fileURL.path): \(error.localizedDescription). Removing file.")
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}

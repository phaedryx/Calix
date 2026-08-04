import Foundation

enum BrowserSecurity {

    // MARK: - Redirect Limit

    static let maxRedirectDepth: Int = 10

    // MARK: - Scheme Validation

    private static let allowedTopLevelSchemes: Set<String> = [
        "http", "https", "about",
    ]

    private static let blockedSubresourceSchemes: Set<String> = [
        "javascript", "data",
    ]

    static func isAllowedTopLevelScheme(_ scheme: String) -> Bool {
        allowedTopLevelSchemes.contains(scheme.lowercased())
    }

    static func isAllowedSubresourceScheme(_ scheme: String) -> Bool {
        !blockedSubresourceSchemes.contains(scheme.lowercased())
    }

    // MARK: - Filename Sanitization

    private static let dangerousExtensions: Set<String> = [
        "exe", "scr", "bat", "cmd", "com", "pif", "vbs", "js", "wsh", "msi",
        "app", "dmg", "pkg", "command", "sh", "workflow", "action",
    ]

    static func sanitizeFilename(_ filename: String) -> String {
        // Strip null bytes first to prevent path truncation attacks
        var sanitized = filename.replacingOccurrences(of: "\0", with: "")

        // Replace dangerous characters
        sanitized = sanitized
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")

        // Strip leading dots
        while sanitized.hasPrefix(".") {
            sanitized = String(sanitized.dropFirst())
        }

        // Remove dangerous double extensions
        // e.g. "file.txt.exe" → "file.txt"
        let nsName = sanitized as NSString
        let ext = nsName.pathExtension.lowercased()
        if dangerousExtensions.contains(ext) {
            sanitized = nsName.deletingPathExtension
        }

        // Truncate to 255 characters
        if sanitized.count > 255 {
            sanitized = String(sanitized.prefix(255))
        }

        // If empty after sanitization, use default name
        if sanitized.isEmpty {
            sanitized = "download"
        }

        return sanitized
    }

    // MARK: - MIME Blocking

    private static let blockedMIMETypes: Set<String> = [
        "application/x-msdownload",
        "application/x-msdos-program",
        "application/x-dosexec",
    ]

    static func isBlockedMIME(_ mime: String) -> Bool {
        blockedMIMETypes.contains(mime.lowercased())
    }

    // MARK: - Download Path Validation

    static func validateDownloadPath(_ path: String, allowedDirectory: String) -> Bool {
        // Standardize to resolve ".." components
        let standardized = (path as NSString).standardizingPath
        // Resolve the parent directory's symlinks (which exists), then append the filename
        let parentDir = (standardized as NSString).deletingLastPathComponent
        let filename = (standardized as NSString).lastPathComponent
        let resolvedParent = (parentDir as NSString).resolvingSymlinksInPath
        let resolvedPath = (resolvedParent as NSString).appendingPathComponent(filename)

        let resolvedAllowed = (allowedDirectory as NSString).resolvingSymlinksInPath

        // Ensure resolved path starts with the allowed directory + path separator
        return resolvedPath.hasPrefix(resolvedAllowed + "/") || resolvedPath == resolvedAllowed
    }
}

import Foundation

public enum WorkspacePaths {
    /// Optional isolated workspace for development and hand tests. Requiring
    /// an absolute path avoids changing storage when the launch cwd changes.
    public static var supportDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["SKYLIGHT_SUPPORT_DIR"],
           path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Skylight", isDirectory: true)
    }
}

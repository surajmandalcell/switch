import Foundation

/// Owner-only files for other targets (the settings store): POSIX mode 0600 in a 0700 folder, on Windows a
/// protected DACL for the process user only. A file that cannot be made owner-only is not written.
public enum PrivateFiles {
    /// Atomically replaces `url` with `data`, creating its folder owner-only first.
    public static func write(_ data: Data, to url: URL) throws {
        try CoreSupport.atomicWrite(data, to: url, fileManager: .default)
    }
}

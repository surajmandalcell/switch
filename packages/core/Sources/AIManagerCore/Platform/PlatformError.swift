import Foundation

/// Thrown by the platform layer for an operation this platform does not implement yet.
/// Callers treat it like any other failure, so an unported check fails closed.
enum PlatformError: Error, Equatable, LocalizedError {
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let what): "\(what) is not supported on this platform yet."
        }
    }
}

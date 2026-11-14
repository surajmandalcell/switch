import Foundation
import AIManagerCore
import SwitchAppModel

struct AccountActionParams: Decodable {
    let accountID: String
    let confirm: String?
}

/// User actions of architecture.md section 2.9. Each goes through the engine's action lane (`-32001` while another
/// runs) and replies `{status, notice?, error?, confirmation?}`.
extension RPCServer {
    static let writeMethods = ["accounts.setDefault", "accounts.check", "usage.refresh"]
    static let confirmationLifetime: TimeInterval = 120

    /// Nil when `method` is not a write method.
    func writeMethod(_ method: String, frame: Data) async throws -> (any Encodable)? {
        guard Self.writeMethods.contains(method) else { return nil }
        let params = try params(AccountActionParams.self, method: method, frame: frame)
        let id = try accountID(params.accountID)
        switch method {
        case "accounts.setDefault":
            let binding = "\(method) \(id.uuidString.lowercased())"
            if let token = params.confirm { try redeem(token, binding) }
            var result = try await engine.setDefault(id, confirmed: params.confirm != nil)
            if result.confirmation != nil { result.confirmation?.token = issue(binding) }
            return result
        case "accounts.check":
            return try await engine.checkAccount(id)
        default:
            return try await engine.refreshUsage(id)
        }
    }

    /// A single-use token, valid for 120 s, bound to the method and its other params (architecture.md 2.6).
    private func issue(_ binding: String) -> String {
        let token = "cf-\(UUID().uuidString.lowercased())"
        lock.lock()
        defer { lock.unlock() }
        let now = clock.now
        confirmations = confirmations.filter { $0.value.expires > now }
        confirmations[token] = (binding, now.addingTimeInterval(Self.confirmationLifetime))
        return token
    }

    private func redeem(_ token: String, _ binding: String) throws {
        lock.lock()
        let entry = confirmations.removeValue(forKey: token)
        lock.unlock()
        guard let entry, entry.binding == binding, entry.expires > clock.now else {
            throw RPCError(-32004, "stale", "The confirmation expired or belongs to another request. Try the action again.")
        }
    }
}

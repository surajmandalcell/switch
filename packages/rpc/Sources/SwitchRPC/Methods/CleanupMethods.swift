import Foundation
import AIManagerCore
import SwitchAppModel

private struct ScanParams: Decodable { let sourceID: String }
private struct ReviewParams: Decodable {
    let scanID: String
    let itemIDs: [String]
}
private struct ApplyParams: Decodable {
    let planID: String?
    let sampleIDs: [Int64]?
    let clearIndex: Bool?
}
private struct BatchParams: Decodable {
    let sourceID: String
    let batchID: String
}

/// Cleanup methods of architecture.md 2.9 (`cleanup.sources`, `cleanup.trashList`, `cleanup.samples` are read
/// methods). Scan and review are reads; apply, restore, and purge take the action lane.
extension RPCServer {
    static let cleanupMethods = ["cleanup.scan", "cleanup.review", "cleanup.apply", "cleanup.restore", "cleanup.purge"]

    /// Nil when `method` is not a cleanup method.
    func cleanupMethod(_ method: String, frame: Data) async throws -> (any Encodable)? {
        switch method {
        case "cleanup.scan":
            let progress = progress(frame)
            let result = try await engine.scanCleanup(
                sourceID: try params(ScanParams.self, method: method, frame: frame).sourceID) { progress?($0) }
            return WireCleanupScan(result.scanID, result.scan)
        case "cleanup.review":
            let params = try params(ReviewParams.self, method: method, frame: frame)
            return WireCleanupPlan(try await engine.reviewCleanup(scanID: try uuid(params.scanID, "scanID"),
                                                                  itemIDs: params.itemIDs))
        case "cleanup.apply":
            let params = try params(ApplyParams.self, method: method, frame: frame)
            return try await engine.applyCleanup(planID: try params.planID.map { try uuid($0, "planID") },
                                                 sampleIDs: params.sampleIDs ?? [], clearIndex: params.clearIndex ?? false)
        case "cleanup.restore", "cleanup.purge":
            let params = try params(BatchParams.self, method: method, frame: frame)
            let batch = try uuid(params.batchID, "batchID")
            guard method == "cleanup.purge" else {
                return try await engine.restoreCleanup(sourceID: params.sourceID, batchID: batch)
            }
            return try await confirmable(method, frame) {
                try await self.engine.purgeCleanup(sourceID: params.sourceID, batchID: batch, confirmed: $0)
            }
        default:
            return nil
        }
    }

    private func uuid(_ text: String, _ name: String) throws -> UUID {
        guard let id = UUID(uuidString: text) else { throw RPCError(-32602, "invalidParams", "\(name) must be a UUID.") }
        return id
    }
}

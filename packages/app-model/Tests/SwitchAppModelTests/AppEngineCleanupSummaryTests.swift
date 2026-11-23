import Foundation
import XCTest
@testable import AIManagerCore
@testable import SwitchAppModel

final class AppEngineCleanupSummaryTests: XCTestCase {
    func testSummaryUsesSelectableItemsAndSkipsRewriteBytes() {
        func item(_ name: String, _ bytes: Int64, protected: Bool = false, rewrite: Bool = false) -> CleanupItem {
            .init(root: 0, path: name, companions: [], title: name, project: nil, updatedAt: Date(), bytes: bytes,
                  isDirectory: false, protectedReason: protected ? "In use now." : nil, inode: 0, device: 0,
                  modifiedAt: 0, rewrite: rewrite)
        }
        func category(_ id: String, _ risk: CleanupCategory.Risk, _ items: [CleanupItem]) -> CleanupCategory {
            .init(id: id, title: id, detail: "", risk: risk, preselected: risk == .safe, byProject: false,
                  ageBased: true, items: items)
        }
        let scan = CleanupScan(sourceID: "codex", categories: [
            category("logs", .safe, [item("log-a", 10), item("log-b", 5), item("active-log", 3, protected: true)]),
            category("conversations", .caution, [item("chat", 20), item("active-chat", 7, protected: true)]),
            category("images", .caution, [item("chat", 4, rewrite: true)]),
        ], totalBytes: 45)
        let summary = CleanupSummary(scan)
        XCTAssertEqual(summary.safeBytes, 15)
        XCTAssertEqual(summary.yourWorkBytes, 20)
        XCTAssertEqual(summary.inUseBytes, 10)
        XCTAssertEqual(summary.safeSourceIDs, ["0:log-a", "0:log-b"])
    }
}

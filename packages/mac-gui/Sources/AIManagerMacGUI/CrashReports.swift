import Foundation
import IndieCrumbCore
import IndieCrumbCrash
import IndieCrumbCrashUI

/// After a crash, the next launch shows the report with a Send button. Nothing is sent unless the person
/// presses Send; closing the window deletes it. The public ingest key comes from the `IndieCrumbKey`
/// Info.plist entry that packaging writes; a build without it shows no prompt.
@MainActor
enum CrashReports {
    static func start() {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "IndieCrumbKey") as? String,
              key.hasPrefix("ic_pub_") else { return }
        // Off: Switch sends no counts of its own; a report the person sends still goes.
        let core = IndieCrumb(endpoint: URL(string: "https://crumb.samhq.app")!, key: key, enabled: false)
        CrashAsk.start(CrashReporter(core), core: core)
    }
}

import Foundation
import XCTest

@testable import OKLabsVocabulary

/// `oklabs.scribeModel` is the one switch between Scribe V3 (default) and V2 for the managed mode;
/// `oklabs.scribeRealtimeModel` forces the live model. Runs in the test process's own defaults domain.
final class ScribeModelSettingsTests: XCTestCase {
    private let keys = ["oklabs.scribeModel", "oklabs.scribeRealtimeModel"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    func testManagedModelDefaultsToV3AndAcceptsOnlyKnownModels() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "oklabs.scribeModel")
        XCTAssertEqual(OKLabsSettings.managedScribeModel, "scribe_v3")
        defaults.set(" Scribe_V2 ", forKey: "oklabs.scribeModel")
        XCTAssertEqual(OKLabsSettings.managedScribeModel, "scribe_v2")
        defaults.set("scribe_v2_medical", forKey: "oklabs.scribeModel")
        XCTAssertEqual(OKLabsSettings.managedScribeModel, "scribe_v2_medical")
        defaults.set("scribe_v2_realtime", forKey: "oklabs.scribeModel")
        XCTAssertEqual(OKLabsSettings.managedScribeModel, "scribe_v3", "a live id is not a mode model")
    }

    func testRealtimeOverrideIsUnsetWhenBlank() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "oklabs.scribeRealtimeModel")
        XCTAssertNil(OKLabsSettings.scribeRealtimeModel)
        defaults.set("  ", forKey: "oklabs.scribeRealtimeModel")
        XCTAssertNil(OKLabsSettings.scribeRealtimeModel)
        defaults.set("scribe_v2_realtime", forKey: "oklabs.scribeRealtimeModel")
        XCTAssertEqual(OKLabsSettings.scribeRealtimeModel, "scribe_v2_realtime")
    }
}

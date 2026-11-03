import Foundation
import XCTest

@testable import OKLabsVocabulary

final class VocabularyCorrectionTests: XCTestCase {
    func testVerbatimDefaultAndExistingExplicitPreference() async throws {
        let defaults = UserDefaults.standard
        let key = "IsAutomaticVocabularyCorrectionEnabled"
        let previousValue = defaults.object(forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let vocabulary = RecordingVocabulary(savedTerms: ["Kubernetes"])
        let original = "Deploy Kubernets today."
        let corrected = "Deploy Kubernetes today."
        // Ensure this fixture exercises a real correction, not a matcher no-op.
        XCTAssertEqual(PhoneticVocabularyMatcher(vocabulary: vocabulary.terms).correct(original), corrected)

        defaults.removeObject(forKey: key)
        OKLabsSettings.registerDefaults(defaults)
        let defaultOutput = try await vocabulary.correctTranscription(original)
        XCTAssertEqual(defaultOutput, original)

        // Registering launch defaults must not overwrite a persisted opt-in.
        defaults.set(true, forKey: key)
        OKLabsSettings.registerDefaults(defaults)
        let optedInOutput = try await vocabulary.correctTranscription(original)
        XCTAssertEqual(optedInOutput, corrected)

        defaults.set(false, forKey: key)
        let optedOutOutput = try await vocabulary.correctTranscription(original)
        XCTAssertEqual(optedOutOutput, original)
    }
}

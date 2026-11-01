import Foundation
import SwiftData

@MainActor
final class CustomVocabularyService {
    static let shared = CustomVocabularyService()

    private init() {}

    func loadSavedVocabulary(from context: ModelContext) -> RecordingVocabulary {
        let descriptor = FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\VocabularyWord.word)])
        let words = (try? context.fetch(descriptor)) ?? []
        #if OKLABS
        // OKLabs fork: terms from `oklabs.keytermsFile` come first, in file order.
        return RecordingVocabulary(savedTerms: OKLabsKeytermsFile.terms() + words.map(\.word))
        #else
        return RecordingVocabulary(savedTerms: words.map(\.word))
        #endif
    }
}

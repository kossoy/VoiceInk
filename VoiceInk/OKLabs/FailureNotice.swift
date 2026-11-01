import Foundation
import SwiftData
import os

/// OKLabs fork: tell the user when a cloud transcription fails.
///
/// Upstream only notifies for Apple Speech errors and otherwise writes
/// "Transcription Failed: …" into History. The recording stays in History either
/// way; "Retry" transcribes it again in batch and copies the text to the
/// clipboard (it never pastes at the cursor, like upstream's retry shortcut).
@MainActor
enum FailureNotice {
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "OKLabsFailureNotice")

    static func show(
        description: String,
        audioURL: URL,
        model: any TranscriptionModel,
        modelContext: ModelContext,
        serviceRegistry: TranscriptionServiceRegistry,
        enhancementService: AIEnhancementService?
    ) {
        guard OKLabsSettings.notifiesOnFailure else { return }
        logger.error("Transcription failed: \(description, privacy: .public)")
        NotificationManager.shared.showNotification(
            title: String(format: String(localized: "Transcription Failed: %@"), description),
            type: .error,
            duration: 12.0,
            actionButton: (
                String(localized: "Retry"),
                {
                    retry(
                        audioURL: audioURL, model: model, modelContext: modelContext,
                        serviceRegistry: serviceRegistry, enhancementService: enhancementService)
                }
            )
        )
    }

    private static func retry(
        audioURL: URL,
        model: any TranscriptionModel,
        modelContext: ModelContext,
        serviceRegistry: TranscriptionServiceRegistry,
        enhancementService: AIEnhancementService?
    ) {
        Task { @MainActor in
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                NotificationManager.shared.showNotification(
                    title: String(localized: "Cannot retry: Audio file not found"), type: .error)
                return
            }
            let service = AudioTranscriptionService(
                modelContext: modelContext, serviceRegistry: serviceRegistry, enhancementService: enhancementService)
            do {
                let result = try await service.retranscribeAudio(from: audioURL, using: model)
                let transcription = result.transcription
                let text =
                    result.enhancementFailure == nil && transcription.enhancedText?.isEmpty == false
                    ? transcription.enhancedText! : transcription.text
                _ = ClipboardManager.copyToClipboard(text)
                NotificationManager.shared.showNotification(
                    title: String(localized: "Copied to clipboard"), type: .success)
            } catch {
                NotificationManager.shared.showNotification(
                    title: String(format: String(localized: "Retry failed: %@"), error.localizedDescription),
                    type: .error)
            }
        }
    }
}

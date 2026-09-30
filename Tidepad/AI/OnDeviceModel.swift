import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device language model, through the Foundation Models framework (macOS 26 and later,
/// with Apple Intelligence turned on). Everything runs on the Mac: nothing is sent anywhere, it works
/// offline, and there's no account or key. On older macOS the AI commands aren't shown; the framework
/// is weakly linked (OTHER_LDFLAGS), so Tidepad still launches there.
enum OnDeviceModel {
    enum Failure: LocalizedError {
        case unsupported
        var errorDescription: String? { "On-device AI needs macOS 26 or later, with Apple Intelligence." }
    }

    /// Whether this macOS has the framework at all (the AI commands are shown).
    static var isSupported: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    /// Why the model can't answer right now, or nil when it can.
    static func unavailableReason() -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return "This Mac can't run Apple Intelligence."
                case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in System Settings ▸ Apple Intelligence & Siri to use this."
                case .modelNotReady: return "Apple Intelligence is still getting ready (its model is downloading). Try again in a few minutes."
                @unknown default: return "Apple Intelligence isn't available right now."
                }
            }
        }
        #endif
        return Failure.unsupported.errorDescription
    }

    /// The answer as it's written: each element is the whole answer so far. Cancelling the task that
    /// reads it stops the model.
    static func answer(_ prompt: AIPrompt) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                #if canImport(FoundationModels)
                if #available(macOS 26.0, *) {
                    do {
                        let session = LanguageModelSession(instructions: prompt.instructions)
                        for try await snapshot in session.streamResponse(to: prompt.prompt) {
                            continuation.yield(snapshot.content)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                    return
                }
                #endif
                continuation.finish(throwing: Failure.unsupported)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A message for an error from the model.
    static func message(for error: Error) -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return "That's more text than the on-device model can take. Select less and try again."
            case .guardrailViolation: return "The on-device model declined to answer this (Apple's safety guardrails)."
            case .unsupportedLanguageOrLocale: return "The on-device model doesn't support this language yet."
            case .assetsUnavailable: return "Apple Intelligence is still getting ready. Try again in a few minutes."
            case .rateLimited: return "The on-device model is busy. Try again in a moment."
            default: break
            }
        }
        #endif
        return error.localizedDescription
    }
}

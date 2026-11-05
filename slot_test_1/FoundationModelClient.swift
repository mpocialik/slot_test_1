import Foundation
import FoundationModels
import Observation

/// How much work the on-device model should put into reasoning before it
/// answers. Lower levels tend to respond faster.
enum ModelReasoningLevel: String, CaseIterable, Identifiable {
    case light
    case moderate
    case deep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light:
            return "Light"
        case .moderate:
            return "Moderate"
        case .deep:
            return "Deep"
        }
    }

    var summary: String {
        switch self {
        case .light:
            return "Fastest responses with minimal reasoning."
        case .moderate:
            return "Balanced response speed and reasoning."
        case .deep:
            return "Slower, more thorough reasoning."
        }
    }

    var contextLevel: ContextOptions.ReasoningLevel {
        switch self {
        case .light:
            return .light
        case .moderate:
            return .moderate
        case .deep:
            return .deep
        }
    }
}

/// Streams responses from Apple's on-device Foundation Model.
@MainActor
@Observable
final class FoundationModelClient {
    private(set) var output = ""
    private(set) var isResponding = false
    private(set) var errorMessage: String?
    private(set) var availability = SystemLanguageModel.default.availability

    /// Whether the selected model supports reasoning levels. The on-device
    /// model does not; reasoning is currently a Private Cloud Compute feature.
    private(set) var supportsReasoning = SystemLanguageModel.default.capabilities.contains(.reasoning)

    /// Reasoning depth used for the next request.
    var reasoningLevel: ModelReasoningLevel = .moderate

    /// Artificial delay between streamed updates, in seconds. `0` shows
    /// tokens as fast as the model produces them.
    var streamUpdateInterval: TimeInterval = 0

    /// When enabled, requests share one conversation session so the model can
    /// refer to earlier transcripts and replies.
    var conversationMemoryEnabled = false

    private var responseTask: Task<Void, Never>?
    private var activeRequestID = UUID()

    private var memorySession: LanguageModelSession?
    private var memoryInstructions = ""
    private var memoryLastTranscript = ""

    var isAvailable: Bool {
        if case .available = availability { return true }
        return false
    }

    var availabilityText: String {
        switch availability {
        case .available:
            return "Foundation Model ready"
        case .unavailable(.deviceNotEligible):
            return "Device not eligible"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is off"
        case .unavailable(.modelNotReady):
            return "Model downloading"
        @unknown default:
            return "Model unavailable"
        }
    }

    func refreshAvailability() {
        let model = SystemLanguageModel.default
        availability = model.availability
        supportsReasoning = model.capabilities.contains(.reasoning)
    }

    func send(_ transcript: String, instructions: String) {
        let transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return }

        refreshAvailability()
        guard isAvailable else {
            errorMessage = "Foundation Models is unavailable: \(availabilityText)."
            return
        }

        let memoryEnabled = conversationMemoryEnabled
        let interruptedResponse = isResponding
        responseTask?.cancel()

        // An interrupted turn may have been partially recorded in the shared
        // session, so start the new request with a clean conversation.
        if interruptedResponse, memoryEnabled {
            resetConversation()
        }

        let requestID = UUID()
        activeRequestID = requestID

        isResponding = true
        output = ""
        errorMessage = nil

        responseTask = Task { [weak self] in
            guard let self else { return }

            defer {
                if self.activeRequestID == requestID {
                    self.isResponding = false
                    self.responseTask = nil
                }
            }

            var didRetryAfterContextOverflow = false

            while !Task.isCancelled, self.activeRequestID == requestID {
                let request = self.prepareRequest(
                    transcript: transcript,
                    instructions: instructions,
                    memoryEnabled: memoryEnabled
                )

                do {
                    // Only request a reasoning level when the model advertises
                    // the `.reasoning` capability. Passing one to the on-device
                    // model throws `unsupportedCapability`.
                    let contextOptions = ContextOptions(
                        reasoningLevel: self.supportsReasoning
                            ? self.reasoningLevel.contextLevel
                            : nil
                    )
                    let stream = request.session.streamResponse(
                        to: request.prompt,
                        contextOptions: contextOptions
                    )

                    var isFirstUpdate = true
                    for try await snapshot in stream {
                        if !isFirstUpdate, self.streamUpdateInterval > 0 {
                            try await Task.sleep(for: .seconds(self.streamUpdateInterval))
                        }
                        isFirstUpdate = false

                        guard !Task.isCancelled, self.activeRequestID == requestID else { return }
                        self.output = snapshot.content
                    }

                    if memoryEnabled, self.conversationMemoryEnabled {
                        self.memoryLastTranscript = transcript
                    }
                    return
                } catch {
                    if memoryEnabled,
                       let languageModelError = error as? LanguageModelError,
                       case .contextSizeExceeded = languageModelError,
                       !didRetryAfterContextOverflow {
                        // Drop the conversation and retry once with a fresh
                        // session containing only the current transcript.
                        didRetryAfterContextOverflow = true
                        self.resetConversation()
                        self.output = ""
                        continue
                    }

                    guard !Task.isCancelled, self.activeRequestID == requestID else { return }
                    self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    if memoryEnabled {
                        self.resetConversation()
                    }
                    return
                }
            }
        }
    }

    func cancel() {
        responseTask?.cancel()
        responseTask = nil
        activeRequestID = UUID()
        isResponding = false
    }

    /// Forgets any retained conversation so the next request starts fresh.
    func resetConversation() {
        memorySession = nil
        memoryInstructions = ""
        memoryLastTranscript = ""
    }

    func clear() {
        cancel()
        resetConversation()
        output = ""
        errorMessage = nil
    }

    private func prepareRequest(
        transcript: String,
        instructions: String,
        memoryEnabled: Bool
    ) -> (session: LanguageModelSession, prompt: String) {
        guard memoryEnabled else {
            resetConversation()
            return (makeSession(instructions: instructions), promptText(from: transcript))
        }

        if let session = memorySession,
           memoryInstructions == instructions {
            let commonLength = commonPrefixLength(memoryLastTranscript, transcript)

            if commonLength > 0 || memoryLastTranscript.isEmpty {
                let delta = String(transcript.dropFirst(commonLength))
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if !delta.isEmpty {
                    // Send only what changed since the previous turn. Earlier
                    // speech and replies are already in the shared session.
                    return (session, promptText(from: delta))
                }

                // Nothing new was said (for example, "Send Now"). Resend the
                // latest transcript while keeping the conversation intact.
                return (session, promptText(from: transcript))
            }
        }

        resetConversation()
        let session = makeSession(instructions: instructions)
        memorySession = session
        memoryInstructions = instructions
        return (session, promptText(from: transcript))
    }

    /// Finds where the live transcript diverges from what the model last saw.
    /// Volatile speech results can be revised when they become final, so this
    /// is not always a simple prefix append.
    private func commonPrefixLength(_ old: String, _ new: String) -> Int {
        zip(old, new).prefix { $0 == $1 }.count
    }

    private func promptText(from text: String) -> String {
        let limit = 6_000
        guard text.count > limit else { return text }
        return "…" + String(text.suffix(limit))
    }

    private func makeSession(instructions: String) -> LanguageModelSession {
        let instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if instructions.isEmpty {
            return LanguageModelSession()
        }
        return LanguageModelSession(instructions: instructions)
    }
}

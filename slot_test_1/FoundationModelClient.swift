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

    /// Reasoning depth used for the next request.
    var reasoningLevel: ModelReasoningLevel = .moderate

    /// Artificial delay between streamed updates, in seconds. `0` shows
    /// tokens as fast as the model produces them.
    var streamUpdateInterval: TimeInterval = 0

    private var responseTask: Task<Void, Never>?
    private var activeRequestID = UUID()

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
        availability = SystemLanguageModel.default.availability
    }

    func send(_ prompt: String, instructions: String) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        refreshAvailability()
        guard isAvailable else {
            errorMessage = "Foundation Models is unavailable: \(availabilityText)."
            return
        }

        responseTask?.cancel()
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

            do {
                let session = self.makeSession(instructions: instructions)
                let contextOptions = ContextOptions(reasoningLevel: self.reasoningLevel.contextLevel)
                let stream = session.streamResponse(to: prompt, contextOptions: contextOptions)

                var isFirstUpdate = true
                for try await snapshot in stream {
                    if !isFirstUpdate, self.streamUpdateInterval > 0 {
                        try await Task.sleep(for: .seconds(self.streamUpdateInterval))
                    }
                    isFirstUpdate = false

                    guard !Task.isCancelled, self.activeRequestID == requestID else { return }
                    self.output = snapshot.content
                }
            } catch {
                guard !Task.isCancelled, self.activeRequestID == requestID else { return }
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func cancel() {
        responseTask?.cancel()
        responseTask = nil
        activeRequestID = UUID()
        isResponding = false
    }

    func clear() {
        cancel()
        output = ""
        errorMessage = nil
    }

    private func makeSession(instructions: String) -> LanguageModelSession {
        let instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if instructions.isEmpty {
            return LanguageModelSession()
        }
        return LanguageModelSession(instructions: instructions)
    }
}

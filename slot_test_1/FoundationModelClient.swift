import Foundation
import FoundationModels
import Observation

/// Streams responses from Apple's on-device Foundation Model.
@MainActor
@Observable
final class FoundationModelClient {
    private(set) var output = ""
    private(set) var isResponding = false
    private(set) var errorMessage: String?
    private(set) var availability = SystemLanguageModel.default.availability

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
                let stream = session.streamResponse(to: prompt)

                for try await snapshot in stream {
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

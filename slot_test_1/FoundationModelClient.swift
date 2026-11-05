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

/// One request sent to the on-device model. Session-only; never persisted.
struct LLMCallRecord: Identifiable {
    let id = UUID()
    let startedAt: Date
    let label: String
    let instructions: String
    let prompt: String
    let options: String
    var output = ""
    var note: String?
    var errorMessage: String?
    var finishedAt: Date?
    var wasCancelled = false

    var isInProgress: Bool { finishedAt == nil }

    var duration: TimeInterval? {
        guard let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }

    var fullRequest: String {
        let system = instructions.isEmpty ? "(no system instructions)" : instructions
        return """
        SYSTEM INSTRUCTIONS
        \(system)

        USER PROMPT
        \(prompt)
        """
    }

    /// Last non-empty line of the prompt, which is the newest speech for an
    /// update and the tail of the ledger for a compaction.
    var preview: String {
        prompt
            .split(whereSeparator: \.isNewline)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map(String.init) ?? prompt
    }

    var statusText: String {
        if isInProgress { return "In progress" }
        if wasCancelled { return "Cancelled" }
        if errorMessage != nil { return "Failed" }
        return "Succeeded"
    }
}

/// Folds finalized speech into a running medical ledger using Apple's
/// on-device Foundation Model.
///
/// The ledger is the conversation state. Every update is a stateless request
/// of the form `previous ledger + new transcript -> updated ledger`; no
/// `LanguageModelSession` history is carried between updates. That keeps the
/// prompt bounded, makes overflow recoverable, and means an ASR revision can
/// never invalidate a shared session.
@MainActor
@Observable
final class FoundationModelClient {
    private(set) var output = ""
    private(set) var isResponding = false
    private(set) var errorMessage: String?
    private(set) var availability = SystemLanguageModel.default.availability

    /// Every model call made during this app session, in order. Not persisted.
    private(set) var history: [LLMCallRecord] = []

    /// Whether the selected model supports reasoning levels. The on-device
    /// model does not; reasoning is currently a Private Cloud Compute feature.
    private(set) var supportsReasoning = SystemLanguageModel.default.capabilities.contains(.reasoning)

    /// Reasoning depth used for the next request.
    var reasoningLevel: ModelReasoningLevel = .moderate

    /// Artificial delay between streamed updates, in seconds. `0` shows
    /// tokens as fast as the model produces them.
    var streamUpdateInterval: TimeInterval = 0

    /// Compact the ledger before it grows past this many characters. The
    /// compaction turn must preserve every fact and tag.
    private static let ledgerCharacterBudget = 6_000

    /// Safety net for one update's transcript. A cadence-sized batch is far
    /// below this; the limit only prevents a runaway prompt.
    private static let transcriptCharacterLimit = 8_000

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
        let model = SystemLanguageModel.default
        availability = model.availability
        supportsReasoning = model.capabilities.contains(.reasoning)
    }

    /// Shows a persisted ledger after launch without starting a request.
    func restoreLedger(_ text: String) {
        guard !isResponding else { return }
        output = text
    }

    /// Folds `newTranscript` into `previousLedger`.
    ///
    /// `completion(true)` means `output` holds a complete replacement ledger.
    /// `completion(false)` means the ledger is unchanged and the caller should
    /// keep the transcript pending for the next attempt. The completion may be
    /// called after a newer request has superseded this one; callers must
    /// ignore stale results.
    func updateLedger(
        previousLedger: String,
        newTranscript: String,
        instructions: String,
        completion: @escaping (Bool) -> Void
    ) {
        let transcript = newTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            completion(false)
            return
        }

        refreshAvailability()
        guard isAvailable else {
            errorMessage = "Foundation Models is unavailable: \(availabilityText)."
            completion(false)
            return
        }

        responseTask?.cancel()

        let requestID = UUID()
        activeRequestID = requestID
        isResponding = true
        errorMessage = nil

        let baseline = previousLedger.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionInstructions = instructions
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop any partial ledger from an interrupted stream.
        output = baseline

        responseTask = Task { [weak self] in
            guard let self else {
                completion(false)
                return
            }

            var succeeded = false

            defer {
                if self.activeRequestID == requestID {
                    self.isResponding = false
                    self.responseTask = nil
                }
                completion(succeeded)
            }

            var ledger = baseline
            var didRetryAfterOverflow = false
            var didRetryAfterShrink = false
            var forceCompaction = false

            while !Task.isCancelled, self.activeRequestID == requestID {
                if forceCompaction || ledger.count > Self.ledgerCharacterBudget {
                    if let compacted = await self.compactLedger(
                        ledger,
                        instructions: sessionInstructions,
                        requestID: requestID
                    ) {
                        ledger = compacted
                    }
                    forceCompaction = false

                    guard !Task.isCancelled, self.activeRequestID == requestID else { return }
                }

                let prompt = self.ledgerPrompt(
                    previousLedger: ledger,
                    newTranscript: transcript,
                    preserveAllBullets: didRetryAfterShrink
                )

                let callLabel: String
                if didRetryAfterShrink {
                    callLabel = "Ledger update — preserve-bullets retry"
                } else if didRetryAfterOverflow {
                    callLabel = "Ledger update — overflow retry"
                } else {
                    callLabel = "Ledger update"
                }
                let callID = self.beginCall(
                    label: callLabel,
                    instructions: sessionInstructions,
                    prompt: prompt
                )

                do {
                    let session = self.makeSession(instructions: sessionInstructions)
                    let stream = session.streamResponse(
                        to: prompt,
                        contextOptions: self.contextOptions()
                    )

                    var isFirstUpdate = true
                    for try await snapshot in stream {
                        if !isFirstUpdate, self.streamUpdateInterval > 0 {
                            try await Task.sleep(for: .seconds(self.streamUpdateInterval))
                        }
                        isFirstUpdate = false

                        guard !Task.isCancelled, self.activeRequestID == requestID else {
                            self.finishCall(callID, output: self.output, cancelled: true)
                            return
                        }
                        self.output = snapshot.content
                    }

                    guard !Task.isCancelled, self.activeRequestID == requestID else {
                        self.finishCall(callID, output: self.output, cancelled: true)
                        return
                    }

                    let newLedger = self.output
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !newLedger.isEmpty else {
                        // Never replace a real ledger with an empty response.
                        self.output = ledger
                        self.errorMessage = "The model returned an empty ledger."
                        self.finishCall(
                            callID,
                            output: "",
                            error: "The model returned an empty ledger."
                        )
                        return
                    }

                    // A ledger must never silently lose clinical facts. If a
                    // large share of the bullets disappeared, retry once with
                    // an explicit preservation reminder before accepting. A
                    // small drop is allowed so duplicate bullets can merge.
                    let previousBullets = Self.bulletCount(in: ledger)
                    let newBullets = Self.bulletCount(in: newLedger)
                    if previousBullets >= 4,
                       newBullets * 4 < previousBullets * 3,
                       !didRetryAfterShrink {
                        didRetryAfterShrink = true
                        self.output = ledger
                        self.finishCall(
                            callID,
                            output: newLedger,
                            note: "Rejected: dropped more than 25% of the previous bullets."
                        )
                        continue
                    }

                    self.finishCall(callID, output: newLedger)
                    succeeded = true
                    return
                } catch {
                    guard !Task.isCancelled, self.activeRequestID == requestID else {
                        self.finishCall(callID, output: self.output, cancelled: true)
                        return
                    }

                    if let languageModelError = error as? LanguageModelError,
                       case .contextSizeExceeded = languageModelError,
                       !didRetryAfterOverflow {
                        // Compact and retry once with a smaller ledger.
                        didRetryAfterOverflow = true
                        forceCompaction = true
                        let partial = self.output
                        self.output = ledger
                        self.finishCall(
                            callID,
                            output: partial,
                            note: "Context limit hit; retrying with a compacted ledger."
                        )
                        continue
                    }

                    let message = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    let partial = self.output
                    self.output = baseline
                    self.errorMessage = message
                    self.finishCall(callID, output: partial, error: message)
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

    func clear() {
        cancel()
        output = ""
        errorMessage = nil
    }

    func clearHistory() {
        history.removeAll()
    }

    // MARK: - Call history

    private func beginCall(
        label: String,
        instructions: String,
        prompt: String
    ) -> UUID {
        let record = LLMCallRecord(
            startedAt: .now,
            label: label,
            instructions: instructions,
            prompt: prompt,
            options: supportsReasoning
                ? "Reasoning: \(reasoningLevel.title)"
                : "Reasoning: none (on-device)"
        )
        history.append(record)
        return record.id
    }

    private func finishCall(
        _ id: UUID,
        output: String,
        note: String? = nil,
        error: String? = nil,
        cancelled: Bool = false
    ) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        var record = history[index]
        record.output = output
        record.note = note
        record.errorMessage = error
        record.wasCancelled = cancelled
        record.finishedAt = .now
        history[index] = record
    }

    // MARK: - Request building

    private func ledgerPrompt(
        previousLedger: String,
        newTranscript: String,
        preserveAllBullets: Bool
    ) -> String {
        let ledger = previousLedger.isEmpty ? "(empty)" : previousLedger

        var prompt = """
        PREVIOUS LEDGER:
        \(ledger)

        NEW TRANSCRIPT:
        \(promptText(from: newTranscript))
        """

        if preserveAllBullets {
            prompt += """


            IMPORTANT: Your previous answer dropped bullets from the ledger. \
            Carry forward every existing bullet exactly as written and only \
            add or update.
            """
        }

        return prompt
    }

    /// Runs a separate, non-streaming-to-UI turn that shortens the ledger
    /// while preserving every fact and tag.
    private func compactLedger(
        _ ledger: String,
        instructions: String,
        requestID: UUID
    ) async -> String? {
        let prompt = """
        Compress the ledger below. Preserve every distinct clinical fact and \
        every <MentionPrescription> or <MentionAppointment> tag. Merge \
        duplicate or redundant bullets and shorten wording. Do not add any \
        new fact. Output only the bulleted list.

        LEDGER:
        \(ledger)
        """

        let callID = beginCall(
            label: "Ledger compaction",
            instructions: instructions,
            prompt: prompt
        )
        var compacted = ""

        do {
            let session = makeSession(instructions: instructions)
            let stream = session.streamResponse(
                to: prompt,
                contextOptions: contextOptions()
            )

            for try await snapshot in stream {
                guard !Task.isCancelled, activeRequestID == requestID else {
                    finishCall(callID, output: compacted, cancelled: true)
                    return nil
                }
                compacted = snapshot.content
            }

            let trimmed = compacted.trimmingCharacters(in: .whitespacesAndNewlines)
            finishCall(
                callID,
                output: trimmed,
                note: trimmed.isEmpty ? "Empty compaction response." : nil
            )
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            finishCall(callID, output: compacted, error: message)
            return nil
        }
    }

    /// Only request a reasoning level when the model advertises the
    /// `.reasoning` capability. Passing one to the on-device model throws
    /// `unsupportedCapability`.
    private func contextOptions() -> ContextOptions {
        ContextOptions(
            reasoningLevel: supportsReasoning ? reasoningLevel.contextLevel : nil
        )
    }

    private func promptText(from text: String) -> String {
        let limit = Self.transcriptCharacterLimit
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

    /// Counts top-level bullets only; nested tag bullets are indented and are
    /// intentionally ignored.
    private static func bulletCount(in text: String) -> Int {
        text.split(whereSeparator: \.isNewline).reduce(into: 0) { count, line in
            if line.hasPrefix("* ") {
                count += 1
            }
        }
    }
}

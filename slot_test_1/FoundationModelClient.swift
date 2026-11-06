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
    /// Optional row preview for prompts whose last line is not meaningful
    /// (for example, an output-format cue).
    var previewOverride: String? = nil
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

    /// Row preview: an explicit override when set, otherwise the last
    /// non-empty prompt line (the tail of the ledger for a compaction).
    var preview: String {
        if let previewOverride,
           !previewOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return previewOverride
        }

        return prompt
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

/// Call-level request tags produced by the second model pass. Tags accumulate
/// for the current call so a detected request stays visible after the
/// transcript moves on. **Clear** starts a new call and resets them.
struct RequestTags {
    var prescriptionRequest = false
    var appointmentRequest = false

    var isEmpty: Bool {
        !prescriptionRequest && !appointmentRequest
    }

    mutating func merge(_ other: RequestTags) {
        prescriptionRequest = prescriptionRequest || other.prescriptionRequest
        appointmentRequest = appointmentRequest || other.appointmentRequest
    }
}

/// Folds finalized speech into a running medical ledger using Apple's
/// on-device Foundation Model.
///
/// The ledger is the conversation state. Every update is a stateless
/// two-pass request:
///
/// 1. `previous ledger + new transcript -> updated ledger`
/// 2. `new transcript -> RX_REQUEST / APPOINTMENT_REQUEST`
///
/// No `LanguageModelSession` history is carried between updates. That keeps
/// the prompt bounded, makes overflow recoverable, and means an ASR revision
/// can never invalidate a shared session.
@MainActor
@Observable
final class FoundationModelClient {
    private(set) var output = ""
    private(set) var isResponding = false
    private(set) var errorMessage: String?
    private(set) var availability = SystemLanguageModel.default.availability

    /// Request flags from the second pass, merged across the current call.
    private(set) var requestTags = RequestTags()

    /// Every model call made during this app session, in order. Not persisted.
    private(set) var history: [LLMCallRecord] = []

    /// Whether the selected model supports reasoning levels. The on-device
    /// model does not; reasoning is currently a Private Cloud Compute feature.
    private(set) var supportsReasoning = SystemLanguageModel.default.capabilities.contains(.reasoning)

    /// Inline copy of the second-pass prompt, used only when
    /// `DefaultClassificationPrompt.md` is missing or empty in the app bundle.
    private static let inlineClassificationPrompt = """
    Analyze the conversation snippet below and classify patient requests.

    Snippet:
    "{{SNIPPET}}"

    Questions:
    1. Did the patient explicitly ask for a medication refill, renewal, new prescription, or dose change? Answer YES or NO.
    2. Did either party explicitly ask to schedule an in-office appointment? Answer YES or NO.

    Output Format:
    RX_REQUEST: [YES/NO]
    APPOINTMENT_REQUEST: [YES/NO]
    """

    /// Template for the second-pass classification prompt, read from
    /// `DefaultClassificationPrompt.md` in the app bundle at launch. The
    /// `{{SNIPPET}}` placeholder marks where the new transcript is inserted;
    /// when it is absent, the snippet is appended to the template instead.
    private static let classificationPromptTemplate: String = {
        guard let url = Bundle.main.url(
            forResource: "DefaultClassificationPrompt",
            withExtension: "md"
        ) else {
            #if DEBUG
            print("DefaultClassificationPrompt.md is missing from the app bundle; using the inline fallback prompt.")
            #endif
            return inlineClassificationPrompt
        }

        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            #if DEBUG
            print("DefaultClassificationPrompt.md could not be read; using the inline fallback prompt.")
            #endif
            return inlineClassificationPrompt
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? inlineClassificationPrompt : trimmed
    }()

    /// Reasoning depth used for the next request.
    var reasoningLevel: ModelReasoningLevel = .moderate

    /// Compact the ledger before it grows past this many characters. The
    /// compaction turn must preserve every fact.
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

    /// Shows persisted request tags after launch without starting a request.
    func restoreRequestTags(_ tags: RequestTags) {
        guard !isResponding else { return }
        requestTags = tags
    }

    /// Runs the two-pass update pipeline for `newTranscript`.
    ///
    /// Pass one folds the speech into `previousLedger`. Pass two classifies
    /// the same snippet for an explicit prescription or in-office appointment
    /// request and merges any flags into `requestTags`. Pass one's answer is
    /// buffered, so `output` is only replaced once both passes succeed.
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
                    prompt: prompt,
                    preview: transcript
                )

                // Pass one is buffered instead of published: users only see
                // the ledger after pass two has accepted the same snippet, so
                // an unclassified intermediate answer is never shown.
                var streamedLedger = ledger

                do {
                    let session = self.makeSession(instructions: sessionInstructions)
                    let stream = session.streamResponse(
                        to: prompt,
                        contextOptions: self.contextOptions()
                    )

                    for try await snapshot in stream {
                        guard !Task.isCancelled, self.activeRequestID == requestID else {
                            self.finishCall(callID, output: streamedLedger, cancelled: true)
                            return
                        }
                        streamedLedger = snapshot.content
                    }

                    guard !Task.isCancelled, self.activeRequestID == requestID else {
                        self.finishCall(callID, output: streamedLedger, cancelled: true)
                        return
                    }

                    let newLedger = streamedLedger
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !newLedger.isEmpty else {
                        // Never replace a real ledger with an empty response.
                        self.output = baseline
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
                        self.finishCall(
                            callID,
                            output: newLedger,
                            note: "Rejected: dropped more than 25% of the previous bullets."
                        )
                        continue
                    }

                    self.finishCall(callID, output: newLedger)

                    // Pass two runs after the ledger is complete. The update
                    // is only committed once classification has finished, so
                    // the tags and ledger appear together to the caller.
                    let classifiedTags = await self.classifyRequests(
                        in: transcript,
                        requestID: requestID
                    )

                    guard !Task.isCancelled, self.activeRequestID == requestID else {
                        return
                    }

                    guard let classifiedTags else {
                        // A thrown classifier error aborts the update so the
                        // caller retries the same transcript. An unparseable
                        // response returns empty tags and does not land here.
                        self.output = baseline
                        if self.errorMessage == nil {
                            self.errorMessage = "The intent classification pass failed."
                        }
                        return
                    }

                    var tags = self.requestTags
                    tags.merge(classifiedTags)
                    self.requestTags = tags

                    self.output = newLedger
                    succeeded = true
                    return
                } catch {
                    guard !Task.isCancelled, self.activeRequestID == requestID else {
                        self.finishCall(callID, output: streamedLedger, cancelled: true)
                        return
                    }

                    if let languageModelError = error as? LanguageModelError,
                       case .contextSizeExceeded = languageModelError,
                       !didRetryAfterOverflow {
                        // Compact and retry once with a smaller ledger.
                        didRetryAfterOverflow = true
                        forceCompaction = true
                        self.finishCall(
                            callID,
                            output: streamedLedger,
                            note: "Context limit hit; retrying with a compacted ledger."
                        )
                        continue
                    }

                    let message = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    self.output = baseline
                    self.errorMessage = message
                    self.finishCall(callID, output: streamedLedger, error: message)
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
        requestTags = RequestTags()
        errorMessage = nil
    }

    func clearHistory() {
        history.removeAll()
    }

    // MARK: - Call history

    private func beginCall(
        label: String,
        instructions: String,
        prompt: String,
        preview: String? = nil
    ) -> UUID {
        var record = LLMCallRecord(
            startedAt: .now,
            label: label,
            instructions: instructions,
            prompt: prompt,
            options: supportsReasoning
                ? "Reasoning: \(reasoningLevel.title)"
                : "Reasoning: none (on-device)"
        )
        record.previewOverride = preview
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
        ---
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

        prompt += "\n\nUPDATED LEDGER:"
        return prompt
    }

    /// Second pass: a self-contained classification prompt over the same
    /// snippet. It deliberately does not receive the ledger, so it cannot
    /// mistake an old request for a new one. The prompt body lives in
    /// `DefaultClassificationPrompt.md`; this method only substitutes the
    /// snippet.
    private func requestClassificationPrompt(for transcript: String) -> String {
        let snippet = promptText(from: transcript)
        let template = Self.classificationPromptTemplate

        guard template.contains("{{SNIPPET}}") else {
            // A custom template that omitted the placeholder still receives
            // the snippet, so classification never runs on empty input.
            return template + "\n\nSnippet:\n\"\(snippet)\""
        }

        return template.replacingOccurrences(of: "{{SNIPPET}}", with: snippet)
    }

    /// Runs the second pass. A thrown error aborts the update so the caller
    /// retries the same transcript; an unparseable response is recorded and
    /// treated as no new tags so a malformed answer cannot block the ledger.
    private func classifyRequests(
        in transcript: String,
        requestID: UUID
    ) async -> RequestTags? {
        let prompt = requestClassificationPrompt(for: transcript)
        let callID = beginCall(
            label: "Intent classification",
            instructions: "",
            prompt: prompt,
            preview: transcript
        )
        var raw = ""

        do {
            let session = makeSession(instructions: "")
            let stream = session.streamResponse(
                to: prompt,
                contextOptions: contextOptions()
            )

            for try await snapshot in stream {
                guard !Task.isCancelled, activeRequestID == requestID else {
                    finishCall(callID, output: raw, cancelled: true)
                    return nil
                }
                raw = snapshot.content
            }

            guard !Task.isCancelled, activeRequestID == requestID else {
                finishCall(callID, output: raw, cancelled: true)
                return nil
            }

            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let tags = Self.parseRequestTags(from: trimmed) else {
                finishCall(
                    callID,
                    output: trimmed,
                    error: "Could not parse RX_REQUEST / APPOINTMENT_REQUEST."
                )
                return RequestTags()
            }

            finishCall(callID, output: trimmed)
            return tags
        } catch {
            guard !Task.isCancelled, activeRequestID == requestID else {
                finishCall(callID, output: raw, cancelled: true)
                return nil
            }

            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            errorMessage = message
            finishCall(callID, output: raw, error: message)
            return nil
        }
    }

    /// Runs a separate, non-streaming-to-UI turn that shortens the ledger
    /// while preserving every fact.
    private func compactLedger(
        _ ledger: String,
        instructions: String,
        requestID: UUID
    ) async -> String? {
        let prompt = """
        Compress the ledger below. Preserve every distinct clinical fact. \
        Merge duplicate or redundant bullets and shorten wording. Do not add \
        any new fact. Output only the bulleted list.

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

    /// Parses the two expected classification lines. A missing key is treated
    /// as NO; a response with neither key is unparseable so the caller can
    /// leave the existing tags untouched.
    private static func parseRequestTags(from text: String) -> RequestTags? {
        let prescriptionKeys = [
            "RX_REQUEST",
            "RX REQUEST",
            "RX:",
            "PRESCRIPTION REQUEST",
            "PRESCRIPTION:"
        ]
        let appointmentKeys = [
            "APPOINTMENT_REQUEST",
            "APPOINTMENT REQUEST",
            "APPOINTMENT:"
        ]
        let allKeys = prescriptionKeys + appointmentKeys

        var tags = RequestTags()
        var foundPrescription = false
        var foundAppointment = false

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            guard !line.isEmpty else { continue }

            if let key = prescriptionKeys.first(where: { line.contains($0) }),
               let value = yesNoValue(in: line, after: key, allKeys: allKeys) {
                foundPrescription = true
                tags.prescriptionRequest = value
            }

            if let key = appointmentKeys.first(where: { line.contains($0) }),
               let value = yesNoValue(in: line, after: key, allKeys: allKeys) {
                foundAppointment = true
                tags.appointmentRequest = value
            }
        }

        guard foundPrescription || foundAppointment else { return nil }
        return tags
    }

    /// Reads the YES/NO value following `key`. The value is cut at the next
    /// known key so a combined one-line response still parses correctly.
    private static func yesNoValue(
        in line: String,
        after key: String,
        allKeys: [String]
    ) -> Bool? {
        guard let keyRange = line.range(of: key) else { return nil }
        var valueText = line[keyRange.upperBound...]

        for otherKey in allKeys where otherKey != key {
            if let otherRange = valueText.range(of: otherKey) {
                valueText = valueText[..<otherRange.lowerBound]
            }
        }

        // Reject an unfilled template such as `[YES/NO]`.
        let compact = valueText.filter { !$0.isWhitespace }
        guard !compact.contains("YES/NO") else { return nil }

        let tokens = valueText
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        guard let first = tokens.first(where: { $0 == "YES" || $0 == "NO" }) else {
            return nil
        }
        return first == "YES"
    }

    /// Counts top-level bullets only; older ledgers may still contain indented
    /// tag sub-bullets, which are intentionally ignored.
    private static func bulletCount(in text: String) -> Int {
        text.split(whereSeparator: \.isNewline).reduce(into: 0) { count, line in
            if line.hasPrefix("* ") {
                count += 1
            }
        }
    }
}

import Foundation
import Observation

@MainActor
@Observable
final class TesterViewModel {
    let transcriber = LiveSpeechTranscriber()
    let model = FoundationModelClient()

    /// Key written by older builds that allowed editing the pass-one prompt
    /// in-app. Removed on launch so the bundled Markdown prompt is always used.
    private static let legacyInstructionsDefaultsKey = "systemInstructions"
    private static let speakerLabelsDefaultsKey = "speakerLabelsEnabled"
    private static let diarizationTuningDefaultsKey = "diarizationTuning"
    private static let ledgerDefaultsKey = "runningLedger"
    private static let prescriptionRequestDefaultsKey = "prescriptionRequestDetected"
    private static let appointmentRequestDefaultsKey = "appointmentRequestDetected"

    /// Name of the bundled file holding the built-in prompt. It is a plain
    /// `.md` file so it can be edited in any text editor without opening Xcode.
    private static let defaultInstructionsResource = "DefaultSystemPrompt"

    /// Live copy of the pass-one prompt, read from `DefaultSystemPrompt.md`
    /// in the app bundle. Edit that file and rebuild to change the prompt.
    ///
    /// `inlineDefaultInstructions` is only used if the resource is missing or
    /// empty so the app still runs with a sane prompt.
    static let defaultInstructions: String = {
        guard let url = Bundle.main.url(
            forResource: defaultInstructionsResource,
            withExtension: "md"
        ) else {
            #if DEBUG
            print("DefaultSystemPrompt.md is missing from the app bundle; using the inline fallback prompt.")
            #endif
            return inlineDefaultInstructions
        }

        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            #if DEBUG
            print("DefaultSystemPrompt.md could not be read; using the inline fallback prompt.")
            #endif
            return inlineDefaultInstructions
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? inlineDefaultInstructions : trimmed
    }()

    private static let inlineDefaultInstructions = """
    You are a medical scribe maintaining a running clinical ledger.

    Task:
    Combine PREVIOUS LEDGER with NEW TRANSCRIPT to create an updated bulleted list.

    Instructions:
    1. Keep all existing facts from PREVIOUS LEDGER.
    2. Add new facts from NEW TRANSCRIPT as clear, concise bullets from the physician's view.
    3. Keep each bullet to one clinical fact (symptom, medication, request, or plan).
    4. Combine duplicate points. Remove conversational filler.
    5. If NEW TRANSCRIPT has no new medical facts, return PREVIOUS LEDGER exactly as it is.

    OUTPUT FORMAT:
    Return ONLY bullet points. No introductory text.
    """

    var autoSendEnabled = true
    var cadenceSeconds: Double = 5

    /// The committed running ledger. This is the model's conversation state:
    /// each update receives it and returns a complete replacement.
    private(set) var ledger = ""

    /// Adds on-device speaker labels to the transcript. The setting is read
    /// when a listening session starts.
    var speakerLabelsEnabled: Bool {
        didSet {
            guard oldValue != speakerLabelsEnabled else { return }
            transcriber.usesSpeakerLabels = speakerLabelsEnabled
            UserDefaults.standard.set(speakerLabelsEnabled, forKey: Self.speakerLabelsDefaultsKey)
        }
    }

    /// Model preset, sensitivity, smoothing, and label fallback tuning.
    /// Persisted as JSON in `UserDefaults`.
    var diarizationTuning: DiarizationTuning {
        didSet {
            guard let data = try? JSONEncoder().encode(diarizationTuning) else { return }
            UserDefaults.standard.set(data, forKey: Self.diarizationTuningDefaultsKey)
        }
    }

    init() {
        // Older builds persisted an in-app pass-one override. Prompts now come
        // only from the bundled Markdown files, so drop any stale value.
        UserDefaults.standard.removeObject(forKey: Self.legacyInstructionsDefaultsKey)

        let savedLedger = UserDefaults.standard.string(forKey: Self.ledgerDefaultsKey) ?? ""
        ledger = savedLedger

        let savedSpeakerLabels = UserDefaults.standard.object(
            forKey: Self.speakerLabelsDefaultsKey
        ) as? Bool ?? true
        speakerLabelsEnabled = savedSpeakerLabels
        transcriber.usesSpeakerLabels = savedSpeakerLabels

        if let data = UserDefaults.standard.data(forKey: Self.diarizationTuningDefaultsKey),
           let savedTuning = try? JSONDecoder().decode(DiarizationTuning.self, from: data) {
            diarizationTuning = savedTuning
        } else {
            diarizationTuning = .default
        }

        model.restoreLedger(savedLedger)
        model.restoreRequestTags(
            RequestTags(
                prescriptionRequest: UserDefaults.standard.bool(
                    forKey: Self.prescriptionRequestDefaultsKey
                ),
                appointmentRequest: UserDefaults.standard.bool(
                    forKey: Self.appointmentRequestDefaultsKey
                )
            )
        )
    }

    /// Fast speech results appear sooner but may be less accurate. Applies
    /// the next time transcription starts.
    var fastTranscription: Bool {
        get { transcriber.usesFastResults }
        set { transcriber.usesFastResults = newValue }
    }

    /// Artificial lag before new transcript text appears, in milliseconds.
    var transcriptionLatencyMilliseconds: Double {
        get { transcriber.transcriptUpdateInterval * 1_000 }
        set { transcriber.setTranscriptUpdateInterval(newValue / 1_000) }
    }

    /// Reasoning depth for the on-device model. Lower levels respond faster.
    var reasoningLevel: ModelReasoningLevel {
        get { model.reasoningLevel }
        set { model.reasoningLevel = newValue }
    }

    private var cadenceTask: Task<Void, Never>?
    private var consumedFinalizedTurnCount = 0
    private var sendGeneration = 0

    var transcript: String {
        transcriber.transcript
    }

    var modelOutput: String {
        model.output
    }

    /// Call-level request tags from the second model pass.
    var prescriptionRequestDetected: Bool {
        model.requestTags.prescriptionRequest
    }

    var appointmentRequestDetected: Bool {
        model.requestTags.appointmentRequest
    }

    var hasRequestTags: Bool {
        !model.requestTags.isEmpty
    }

    /// Copy text includes the request tags alongside the ledger, since the
    /// tags are displayed as chips rather than as ledger bullets.
    var ledgerCopyText: String {
        var parts: [String] = []

        let output = model.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty {
            parts.append(output)
        }
        if model.requestTags.prescriptionRequest {
            parts.append("- [TAG: Rx Request]")
        }
        if model.requestTags.appointmentRequest {
            parts.append("- [TAG: Appointment Request]")
        }

        return parts.joined(separator: "\n")
    }

    var isListening: Bool {
        transcriber.isListening
    }

    var isPreparing: Bool {
        transcriber.isPreparing
    }

    var isResponding: Bool {
        model.isResponding
    }

    /// Whether the current model can honor a reasoning level. The on-device
    /// model cannot, so the reasoning level setting is disabled in that case.
    var modelSupportsReasoning: Bool {
        model.supportsReasoning
    }

    var errorMessage: String? {
        transcriber.errorMessage ?? model.errorMessage
    }

    var needsPermissionSettings: Bool {
        transcriber.needsPermissionSettings
    }

    var speakerDiarizationStatus: String {
        transcriber.diarization.statusMessage
    }

    var speakerDiarizationError: String? {
        transcriber.diarization.errorMessage
    }

    var speakerDiarizationProgress: Double? {
        transcriber.diarization.downloadProgress
    }

    var isSpeakerDiarizationPreparing: Bool {
        transcriber.diarization.isPreparing
    }

    var isSpeakerDiarizationModelLoading: Bool {
        transcriber.diarization.isModelLoading
    }

    var isSpeakerDiarizationBusy: Bool {
        transcriber.diarization.isPreparing || transcriber.diarization.isModelLoading
    }

    var isSpeakerDiarizationRunning: Bool {
        transcriber.diarization.isRunning
    }

    var speakerDiarizationShortStatus: String {
        if transcriber.diarization.errorMessage != nil {
            return "Speakers unavailable"
        }
        if isSpeakerDiarizationBusy {
            return "Speakers loading"
        }
        if transcriber.diarization.isRunning {
            return "Speakers on"
        }
        if transcriber.diarization.isModelLoaded {
            return "Speakers ready"
        }
        return "Speakers off"
    }

    /// Longer status used by the on-screen setup indicator.
    var speakerDiarizationDisplayStatus: String {
        if transcriber.diarization.errorMessage != nil {
            return "Speaker labels unavailable"
        }
        if transcriber.diarization.isPreparing {
            return transcriber.diarization.statusMessage
        }
        if transcriber.diarization.isModelLoading {
            return "Loading speaker model…"
        }
        if transcriber.diarization.isRunning {
            return "Speaker labels on"
        }
        if transcriber.diarization.isModelLoaded {
            return "Speaker labels ready"
        }
        return "Speaker model not loaded yet"
    }

    var speakerDiarizationDetail: String {
        if let error = transcriber.diarization.errorMessage {
            return error
        }
        if isSpeakerDiarizationBusy {
            return "One-time download and compile. The model is cached on this device for next time."
        }
        if transcriber.diarization.isRunning {
            return "Who-is-speaking labels are being applied to the live transcript."
        }
        if transcriber.diarization.isModelLoaded {
            return "The speaker model is loaded. Labels will appear when you start listening."
        }
        return "The speaker model downloads the first time you start listening. Transcription itself always uses Apple's Speech framework."
    }

    var isSpeakerDiarizationReady: Bool {
        transcriber.diarization.isModelLoaded
    }

    var canClearSpeakerModelCache: Bool {
        !isListening
            && !isPreparing
            && !isSpeakerDiarizationBusy
            && !transcriber.diarization.isRunning
    }

    var canSendNow: Bool {
        transcriber.finalizedTurnCount > consumedFinalizedTurnCount && model.isAvailable
    }

    func resetDiarizationTuning() {
        diarizationTuning = .default
    }

    func clearSpeakerModelCache() async {
        await transcriber.diarization.clearModelCache()
    }

    func startListening() async {
        transcriber.diarizationTuning = diarizationTuning
        await transcriber.start()

        if transcriber.isListening {
            model.refreshAvailability()
            startCadenceLoop()
        }
    }

    func stopListening() async {
        cadenceTask?.cancel()
        cadenceTask = nil
        await transcriber.stop()
    }

    func sendNow() {
        flushPendingTranscript(force: true)
    }

    func clear() {
        sendGeneration += 1
        transcriber.clear()
        model.clear()
        consumedFinalizedTurnCount = 0
        ledger = ""
        persistLedger()
        persistRequestTags()
    }

    func refreshModelAvailability() {
        model.refreshAvailability()
    }

    private func startCadenceLoop() {
        cadenceTask?.cancel()

        cadenceTask = Task { [weak self] in
            var lastSend = Date.now

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }

                guard self.autoSendEnabled, self.transcriber.isListening else {
                    lastSend = .now
                    continue
                }

                if Date.now.timeIntervalSince(lastSend) >= self.cadenceSeconds {
                    lastSend = .now
                    self.flushPendingTranscript()
                }
            }
        }
    }

    /// Sends the next batch of finalized speech. The ledger cursor only moves
    /// forward after the model returns a complete replacement ledger, so a
    /// failed or interrupted update is retried with the same text.
    private func flushPendingTranscript(force: Bool = false) {
        let total = transcriber.finalizedTurnCount
        guard total > consumedFinalizedTurnCount, model.isAvailable else { return }

        // Auto-send never overlaps an in-flight update. Send Now may interrupt.
        guard force || !model.isResponding else { return }

        let start = consumedFinalizedTurnCount
        let text = transcriber.finalizedTranscriptText(from: start)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            consumedFinalizedTurnCount = total
            return
        }

        sendGeneration += 1
        let generation = sendGeneration
        let end = total

        model.updateLedger(
            previousLedger: ledger,
            newTranscript: text,
            instructions: Self.defaultInstructions
        ) { [weak self] succeeded in
            guard let self, self.sendGeneration == generation else { return }
            guard succeeded else { return }

            // The transcript may have advanced while the model was responding;
            // commit only the turns included in this request.
            self.consumedFinalizedTurnCount = end
            self.ledger = self.model.output
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.persistLedger()
            self.persistRequestTags()
        }
    }

    private func persistLedger() {
        if ledger.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.ledgerDefaultsKey)
        } else {
            UserDefaults.standard.set(ledger, forKey: Self.ledgerDefaultsKey)
        }
    }

    private func persistRequestTags() {
        let tags = model.requestTags

        if tags.prescriptionRequest {
            UserDefaults.standard.set(true, forKey: Self.prescriptionRequestDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.prescriptionRequestDefaultsKey)
        }

        if tags.appointmentRequest {
            UserDefaults.standard.set(true, forKey: Self.appointmentRequestDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.appointmentRequestDefaultsKey)
        }
    }
}

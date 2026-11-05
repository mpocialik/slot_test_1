import Foundation
import Observation

@MainActor
@Observable
final class TesterViewModel {
    let transcriber = LiveSpeechTranscriber()
    let model = FoundationModelClient()

    private static let instructionsDefaultsKey = "systemInstructions"
    private static let speakerLabelsDefaultsKey = "speakerLabelsEnabled"
    private static let diarizationTuningDefaultsKey = "diarizationTuning"
    private static let ledgerDefaultsKey = "runningLedger"

    /// Name of the bundled file holding the built-in prompt. It is a plain
    /// `.md` file so it can be edited in any text editor without opening Xcode.
    private static let defaultInstructionsResource = "DefaultSystemPrompt"

    /// Live copy of the built-in prompt, read from `DefaultSystemPrompt.md`
    /// in the app bundle. Edit that file and rebuild to change the default.
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
    You are a precise medical scribe maintaining a running ledger of a patient \
    phone call. Each update gives you the PREVIOUS LEDGER and the NEW TRANSCRIPT \
    of finalized speech. Carry forward every existing bullet and add atomic \
    bullets for new clinical facts, symptoms, requests, and doctor actions. Never \
    invent facts and never delete a bullet; rewrite a bullet in place if new \
    speech corrects it. Infer which speaker is the physician or patient from \
    content; "Speaker 1"/"Speaker 2" numbers are not stable. Tag a bullet with \
    <MentionPrescription> only for an explicit prescription request (refill, \
    renewal, new prescription, or dosage change), and with <MentionAppointment> \
    only when scheduling an in-office appointment is explicitly discussed. If \
    the new transcript has no new clinical data, return the previous ledger \
    unchanged. Output only the complete bulleted ledger.
    """

    /// Persisted in `UserDefaults` so custom instructions survive relaunches.
    /// The saved value is dropped when the text matches the built-in prompt so
    /// later edits to `DefaultSystemPrompt.md` are picked up after a rebuild.
    var instructions: String {
        didSet {
            if instructions == Self.defaultInstructions {
                UserDefaults.standard.removeObject(forKey: Self.instructionsDefaultsKey)
            } else {
                UserDefaults.standard.set(instructions, forKey: Self.instructionsDefaultsKey)
            }
        }
    }

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
        instructions = UserDefaults.standard.string(forKey: Self.instructionsDefaultsKey)
            ?? Self.defaultInstructions

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

    /// Artificial delay between streamed model updates, in milliseconds.
    var llmStreamLatencyMilliseconds: Double {
        get { model.streamUpdateInterval * 1_000 }
        set { model.streamUpdateInterval = max(0, newValue / 1_000) }
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

    /// Restores the built-in prompt from `DefaultSystemPrompt.md`, discarding
    /// any custom text saved in `UserDefaults`.
    func resetInstructions() {
        instructions = Self.defaultInstructions
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
            instructions: instructions
        ) { [weak self] succeeded in
            guard let self, self.sendGeneration == generation else { return }
            guard succeeded else { return }

            // The transcript may have advanced while the model was responding;
            // commit only the turns included in this request.
            self.consumedFinalizedTurnCount = end
            self.ledger = self.model.output
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.persistLedger()
        }
    }

    private func persistLedger() {
        if ledger.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.ledgerDefaultsKey)
        } else {
            UserDefaults.standard.set(ledger, forKey: Self.ledgerDefaultsKey)
        }
    }
}

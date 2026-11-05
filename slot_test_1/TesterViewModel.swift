import Foundation
import Observation

@MainActor
@Observable
final class TesterViewModel {
    let transcriber = LiveSpeechTranscriber()
    let model = FoundationModelClient()

    private static let instructionsDefaultsKey = "systemInstructions"
    private static let speakerLabelsDefaultsKey = "speakerLabelsEnabled"

    private static let defaultInstructions = """
    You are a helpful assistant running inside a live speech transcription tester. \
    The user's message is a speech transcript and may contain recognition errors. \
    The transcript may label turns as "Speaker 1:", "Speaker 2:", and so on. \
    Reply concisely in plain text, in the same language as the transcript.
    """

    /// Persisted in `UserDefaults` so custom instructions survive relaunches.
    var instructions: String {
        didSet {
            UserDefaults.standard.set(instructions, forKey: Self.instructionsDefaultsKey)
        }
    }

    var autoSendEnabled = true
    var cadenceSeconds: Double = 5

    /// Adds on-device speaker labels to the transcript. The setting is read
    /// when a listening session starts.
    var speakerLabelsEnabled: Bool {
        didSet {
            guard oldValue != speakerLabelsEnabled else { return }
            transcriber.usesSpeakerLabels = speakerLabelsEnabled
            UserDefaults.standard.set(speakerLabelsEnabled, forKey: Self.speakerLabelsDefaultsKey)
        }
    }

    init() {
        instructions = UserDefaults.standard.string(forKey: Self.instructionsDefaultsKey)
            ?? Self.defaultInstructions

        let savedSpeakerLabels = UserDefaults.standard.object(
            forKey: Self.speakerLabelsDefaultsKey
        ) as? Bool ?? true
        speakerLabelsEnabled = savedSpeakerLabels
        transcriber.usesSpeakerLabels = savedSpeakerLabels
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

    /// When enabled, the model keeps earlier transcripts and replies in context.
    /// Turning memory off or on starts a fresh conversation.
    var conversationMemoryEnabled: Bool {
        get { model.conversationMemoryEnabled }
        set {
            guard newValue != model.conversationMemoryEnabled else { return }
            model.conversationMemoryEnabled = newValue
            model.resetConversation()
        }
    }

    private var cadenceTask: Task<Void, Never>?
    private var lastSentTranscript = ""

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

    var isSpeakerDiarizationRunning: Bool {
        transcriber.diarization.isRunning
    }

    var speakerDiarizationShortStatus: String {
        if transcriber.diarization.errorMessage != nil {
            return "Speakers unavailable"
        }
        if transcriber.diarization.isPreparing {
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

    var canSendNow: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.isAvailable
    }

    func startListening() async {
        await transcriber.start()

        if transcriber.isListening {
            lastSentTranscript = transcriber.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
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
        sendTranscriptIfNeeded(force: true)
    }

    func clear() {
        transcriber.clear()
        model.clear()
        lastSentTranscript = ""
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
                    self.sendTranscriptIfNeeded()
                }
            }
        }
    }

    private func sendTranscriptIfNeeded(force: Bool = false) {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, model.isAvailable else { return }
        guard force || text != lastSentTranscript else { return }

        // Auto-send never overlaps an in-flight generation. If the model is
        // still responding, the next tick will pick up the newest transcript.
        guard force || !model.isResponding else { return }

        lastSentTranscript = text
        model.send(text, instructions: instructions)
    }
}

import AVFoundation
import CoreMedia
import Foundation
import Observation
import Speech

/// Captures microphone audio and turns it into a live, on-device transcript
/// using the Speech framework's `SpeechAnalyzer` / `SpeechTranscriber` APIs.
@MainActor
@Observable
final class LiveSpeechTranscriber {
    private(set) var transcript = ""
    private(set) var isListening = false
    private(set) var isPreparing = false
    private(set) var statusMessage = "Idle"
    private(set) var errorMessage: String?
    private(set) var needsPermissionSettings = false

    /// When enabled, asks the speech model for faster (but potentially less
    /// accurate) results. Takes effect the next time transcription starts.
    var usesFastResults = false

    /// Artificial delay applied before new transcript text is shown, in
    /// seconds. `0` publishes results in real time.
    private(set) var transcriptUpdateInterval: TimeInterval = 0

    /// When enabled, the transcript is annotated with on-device speaker
    /// labels. The setting is read when a listening session starts.
    var usesSpeakerLabels = true {
        didSet {
            guard oldValue != usesSpeakerLabels else { return }
            flushTranscriptDisplay()
        }
    }

    /// Diarization preset and timeline tuning. Read when a session starts.
    var diarizationTuning: DiarizationTuning = .default

    /// On-device speaker diarization state and speaker-label lookup.
    let diarization: SpeakerDiarizationService

    private let diarizationCapture: DiarizationAudioCapture
    private var diarizationTask: Task<Void, Never>?
    private var sessionUsesSpeakerLabels = false

    private var sessionGeneration = 0

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var analysisTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converterBox: AudioConverterBox?
    private var tapInstalled = false

    private struct TranscriptTurn: Identifiable {
        let id = UUID()
        let text: String
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    private var finalizedTurns: [TranscriptTurn] = []

    /// Number of finalized turns produced in this call. Callers keep their own
    /// cursor so they can consume each timed batch exactly once.
    private(set) var finalizedTurnCount = 0
    private var volatileTurn: TranscriptTurn?

    /// The audio-time position where the current listening session begins.
    /// Speech and diarization timelines both restart at zero each session, so
    /// this keeps turns from different sessions comparable.
    private var sessionTimelineStart: TimeInterval = 0
    private var timelineOffset: TimeInterval = 0
    private var lastTurnEnd: TimeInterval = 0

    private var displayTask: Task<Void, Never>?
    private var lastDisplayUpdate = Date.distantPast

    init() {
        let capture = DiarizationAudioCapture()
        diarizationCapture = capture
        let service = SpeakerDiarizationService(capture: capture)
        diarization = service
        service.onSegmentsChanged = { [weak self] in
            self?.diarizationDidUpdate()
        }
    }

    // MARK: - Public controls

    func start() async {
        guard !isListening, !isPreparing else { return }

        isPreparing = true
        defer { isPreparing = false }

        errorMessage = nil
        needsPermissionSettings = false
        statusMessage = "Requesting permissions…"

        displayTask?.cancel()
        displayTask = nil
        lastDisplayUpdate = .distantPast

        sessionGeneration += 1
        let generation = sessionGeneration

        do {
            try await requestPermissions()
            guard generation == sessionGeneration else { return }

            try await beginTranscription(generation: generation)
            guard generation == sessionGeneration else {
                await tearDown()
                return
            }

            isListening = true
            statusMessage = "Listening"
        } catch {
            await tearDown()
            present(error)
        }
    }

    func stop() async {
        sessionGeneration += 1

        guard isListening || isPreparing || analyzer != nil else { return }
        if errorMessage == nil {
            statusMessage = "Stopped"
        }

        // Stop accepting results before committing the volatile tail so a late
        // final result cannot duplicate the text we keep on screen.
        resultsTask?.cancel()
        resultsTask = nil
        commitVolatileTranscript()

        await tearDown()
    }

    func clear() {
        displayTask?.cancel()
        displayTask = nil
        transcript = ""
        finalizedTurns.removeAll()
        finalizedTurnCount = 0
        volatileTurn = nil
        lastDisplayUpdate = .distantPast
        lastTurnEnd = sessionTimelineStart
        diarization.clearLabels()

        if !isListening {
            sessionTimelineStart = 0
            timelineOffset = 0
            lastTurnEnd = 0
        }
    }

    /// Updates the artificial display lag. Cancels any pending update and
    /// publishes the current transcript immediately.
    func setTranscriptUpdateInterval(_ interval: TimeInterval) {
        transcriptUpdateInterval = max(0, interval)
        flushTranscriptDisplay()
    }

    private func commitVolatileTranscript() {
        if let volatileTurn {
            finalizedTurns.append(volatileTurn)
            finalizedTurnCount += 1
            self.volatileTurn = nil
        }
        flushTranscriptDisplay()
    }

    /// Renders finalized turns starting at `startIndex` with the speaker labels
    /// available right now. Callers consume each batch once; labels that arrive
    /// later do not rewrite text that was already sent.
    func finalizedTranscriptText(from startIndex: Int) -> String {
        guard startIndex >= 0, startIndex < finalizedTurns.count else { return "" }
        return render(turns: Array(finalizedTurns[startIndex...]))
    }

    // MARK: - Permissions

    private func requestPermissions() async throws {
        let speechStatus = await requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            throw CaptureError.speechPermissionDenied
        }

        let microphoneGranted = await requestMicrophoneAccess()
        guard microphoneGranted else {
            throw CaptureError.microphonePermissionDenied
        }
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    // MARK: - Setup

    private func beginTranscription(generation: Int) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw CaptureError.speechUnavailable
        }

        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw CaptureError.unsupportedLocale
        }
        guard generation == sessionGeneration else { return }

        statusMessage = "Preparing speech model…"

        var reportingOptions: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
        if usesFastResults {
            reportingOptions.insert(.fastResults)
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: reportingOptions,
            attributeOptions: []
        )
        self.transcriber = transcriber

        if let installationRequest = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            statusMessage = "Downloading speech model…"
            try await installationRequest.downloadAndInstall()
        }
        guard generation == sessionGeneration else { return }

        statusMessage = "Starting microphone…"
        try configureAudioSession()

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputContinuation = continuation

        let converter = try await AnalyzerInputConverter.converter(compatibleWith: [transcriber])
        guard generation == sessionGeneration else { return }
        let converterBox = AudioConverterBox(converter)
        self.converterBox = converterBox

        startConsumingResults(from: transcriber)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // SpeechAnalyzer and the diarizer each start their own timeline at
        // zero. Offset this session so labels stay aligned when the user stops
        // and starts listening without clearing the transcript.
        sessionTimelineStart = timelineOffset
        lastTurnEnd = sessionTimelineStart
        sessionUsesSpeakerLabels = usesSpeakerLabels
        let diarizationGeneration = diarization.startCapture(
            enabled: usesSpeakerLabels,
            timeOffset: sessionTimelineStart,
            tuning: diarizationTuning
        )
        if usesSpeakerLabels {
            diarizationTask?.cancel()
            diarizationTask = Task { [weak self] in
                await self?.diarization.loadAndStartProcessing(generation: diarizationGeneration)
            }
        }

        try startAudioEngine(converter: converterBox, continuation: continuation)
        guard generation == sessionGeneration else { return }

        analysisTask = Task { [weak self] in
            do {
                try await analyzer.start(inputSequence: stream)
            } catch {
                guard !Task.isCancelled else { return }
                self?.reportRuntimeError(error)
            }
        }
    }

    private func startConsumingResults(from transcriber: SpeechTranscriber) {
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, !Task.isCancelled else { return }
                    self.consume(result)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.reportRuntimeError(error)
            }
        }
    }

    private func consume(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)
        guard !text.isEmpty else { return }

        let start = seconds(result.range.start).map { sessionTimelineStart + $0 } ?? lastTurnEnd
        let end = seconds(result.range.end).map { sessionTimelineStart + $0 } ?? start
        let turn = TranscriptTurn(
            text: text,
            startTime: max(sessionTimelineStart, start),
            endTime: max(start, end)
        )

        if result.isFinal {
            if let volatileTurn, rangesOverlap(volatileTurn, turn) {
                self.volatileTurn = nil
            }
            finalizedTurns.append(turn)
            finalizedTurnCount += 1
        } else {
            volatileTurn = turn
        }

        lastTurnEnd = max(lastTurnEnd, turn.endTime)
        publishTranscript()
    }

    private func seconds(_ time: CMTime) -> TimeInterval? {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    private func rangesOverlap(_ first: TranscriptTurn, _ second: TranscriptTurn) -> Bool {
        if first.startTime == second.startTime { return true }
        return first.startTime < second.endTime && second.startTime < first.endTime
    }

    /// Throttles visible transcript updates so the display can be slowed down
    /// intentionally while testing. The transcript state itself is always
    /// current; only the published `transcript` is delayed.
    private func publishTranscript() {
        let interval = transcriptUpdateInterval
        guard interval > 0 else {
            flushTranscriptDisplay()
            return
        }

        let elapsed = Date.now.timeIntervalSince(lastDisplayUpdate)
        if elapsed >= interval {
            flushTranscriptDisplay()
            return
        }

        guard displayTask == nil else { return }

        let delay = interval - elapsed
        displayTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.displayTask = nil
            self.showCurrentTranscript()
        }
    }

    private func flushTranscriptDisplay() {
        displayTask?.cancel()
        displayTask = nil
        showCurrentTranscript()
    }

    private func showCurrentTranscript() {
        lastDisplayUpdate = .now
        transcript = renderTranscript()
    }

    private func diarizationDidUpdate() {
        // Speaker labels can arrive after the words are already on screen.
        // Refresh immediately rather than waiting for the display throttle.
        flushTranscriptDisplay()
    }

    private func renderTranscript() -> String {
        let turns = finalizedTurns + (volatileTurn.map { [$0] } ?? [])
        return render(turns: turns)
    }

    private func render(turns: [TranscriptTurn]) -> String {
        guard usesSpeakerLabels, sessionUsesSpeakerLabels, diarization.hasSpeakers else {
            return turns.map(\.text).joined()
        }

        var groups: [(slot: Int?, text: String)] = []
        for turn in turns {
            let slot = diarization.speakerSlot(for: turn.startTime...turn.endTime)
            if let last = groups.last, last.slot == slot {
                groups[groups.count - 1].text += turn.text
            } else {
                groups.append((slot, turn.text))
            }
        }

        let rendered = groups.compactMap { group -> String? in
            let text = group.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if let slot = group.slot, let number = diarization.speakerNumber(for: slot) {
                return "Speaker \(number): \(text)"
            }
            return text
        }

        return rendered.joined(separator: "\n")
    }

    private func startAudioEngine(
        converter: AudioConverterBox,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noMicrophone
        }

        let speakerCapture = diarizationCapture
        inputNode.installTap(onBus: 0, bufferSize: 8_192, format: inputFormat) { buffer, _ in
            do {
                // A nil start time means "immediately after the previous
                // buffer", keeping the analyzer timeline aligned with the
                // separate 16 kHz diarization stream.
                for input in try converter.convert(buffer, at: nil) {
                    continuation.yield(input)
                }

                // Only feed diarization buffers that also reached the speech
                // analyzer, so the two timelines cannot drift apart.
                speakerCapture.append(buffer)
            } catch {
                // A failed buffer is skipped; capture continues with the next one.
            }
        }
        tapInstalled = true

        audioEngine.prepare()

        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
            throw CaptureError.audioEngineFailed(error)
        }
    }

    private func configureAudioSession() throws {
        #if os(iOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        #endif
    }

    // MARK: - Teardown

    private func tearDown() async {
        isListening = false

        diarizationTask?.cancel()
        diarizationTask = nil

        displayTask?.cancel()
        displayTask = nil

        analysisTask?.cancel()
        analysisTask = nil
        resultsTask?.cancel()
        resultsTask = nil

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        if let converterBox {
            for input in (try? converterBox.flush()) ?? [] {
                inputContinuation?.yield(input)
            }
        }
        self.converterBox = nil

        inputContinuation?.finish()
        inputContinuation = nil

        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        self.analyzer = nil
        self.transcriber = nil

        // Do not wait for a first-run model download to finish. The detached
        // load keeps the model for the next session; its continuation checks
        // the session generation before starting inference.
        await diarization.endSession()
        updateTimelineOffset()

        #if os(iOS) || os(visionOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func updateTimelineOffset() {
        let lastTurn = finalizedTurns.map(\.endTime).max() ?? 0
        let lastSpeaker = diarization.segments.map(\.endTime).max() ?? 0
        timelineOffset = max(timelineOffset, lastTurn, lastSpeaker)
    }

    // MARK: - Errors

    private func reportRuntimeError(_ error: Error) {
        guard isListening else { return }
        present(error)
        Task { await self.stop() }
    }

    private func present(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        needsPermissionSettings = (error as? CaptureError)?.requiresSettings ?? false
        statusMessage = "Error"
    }
}

// MARK: - Helpers

/// `AnalyzerInputConverter` is used only from the audio render thread.
/// This wrapper keeps that access explicit for the compiler.
private final class AudioConverterBox: @unchecked Sendable {
    private let converter: AnalyzerInputConverter
    private let lock = NSLock()

    init(_ converter: AnalyzerInputConverter) {
        self.converter = converter
    }

    func convert(_ buffer: AVAudioBuffer, at time: AVAudioTime?) throws -> [AnalyzerInput] {
        lock.lock()
        defer { lock.unlock() }
        return try converter.convert(buffer, at: time)
    }

    func flush() throws -> [AnalyzerInput] {
        lock.lock()
        defer { lock.unlock() }
        return try converter.flush()
    }
}

private enum CaptureError: LocalizedError {
    case speechPermissionDenied
    case microphonePermissionDenied
    case speechUnavailable
    case unsupportedLocale
    case noMicrophone
    case audioEngineFailed(Error)

    var requiresSettings: Bool {
        switch self {
        case .speechPermissionDenied, .microphonePermissionDenied:
            return true
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .speechPermissionDenied:
            return "Speech recognition permission is off. Enable it in Settings to transcribe your voice."
        case .microphonePermissionDenied:
            return "Microphone permission is off. Enable it in Settings to use live transcription."
        case .speechUnavailable:
            return "Live speech transcription isn't available on this device."
        case .unsupportedLocale:
            return "Live transcription isn't available for your current language yet."
        case .noMicrophone:
            return "No microphone input was found."
        case .audioEngineFailed(let error):
            return "The microphone couldn't start: \(error.localizedDescription)"
        }
    }
}

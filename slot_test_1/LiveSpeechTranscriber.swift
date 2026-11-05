import AVFoundation
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

    private var sessionGeneration = 0

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var analysisTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converterBox: AudioConverterBox?
    private var tapInstalled = false

    private var finalizedTranscript = ""
    private var volatileTranscript = ""

    private var displayTask: Task<Void, Never>?
    private var lastDisplayUpdate = Date.distantPast

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
        finalizedTranscript = ""
        volatileTranscript = ""
        lastDisplayUpdate = .distantPast
    }

    /// Updates the artificial display lag. Cancels any pending update and
    /// publishes the current transcript immediately.
    func setTranscriptUpdateInterval(_ interval: TimeInterval) {
        transcriptUpdateInterval = max(0, interval)
        flushTranscriptDisplay()
    }

    private func commitVolatileTranscript() {
        if !volatileTranscript.isEmpty {
            finalizedTranscript += volatileTranscript
            volatileTranscript = ""
        }
        flushTranscriptDisplay()
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
        let segment = String(result.text.characters)

        if result.isFinal {
            finalizedTranscript += segment
            volatileTranscript = ""
        } else {
            volatileTranscript = segment
        }

        publishTranscript()
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
        transcript = finalizedTranscript + volatileTranscript
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

        inputNode.installTap(onBus: 0, bufferSize: 8_192, format: inputFormat) { buffer, time in
            do {
                for input in try converter.convert(buffer, at: time) {
                    continuation.yield(input)
                }
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

        #if os(iOS) || os(visionOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
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

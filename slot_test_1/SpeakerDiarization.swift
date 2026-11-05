import AVFoundation
import FluidAudio
import Foundation
import Observation

/// A speaker turn reported by the on-device diarizer.
///
/// Times are relative to the whole app session, so turns from separate
/// listening sessions can be compared with transcript timestamps.
nonisolated struct SpeakerSegment: Sendable, Equatable {
    /// Unique within the service. Each listening session gets a fresh key
    /// range so speakers from earlier sessions keep their labels.
    let speakerKey: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let isFinalized: Bool
}

/// Sortformer streaming presets exposed in the tuning UI.
nonisolated enum DiarizationModelPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case fast
    case balanced
    case efficient

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .efficient: return "Efficient"
        }
    }

    var summary: String {
        switch self {
        case .fast:
            return "Lowest compute and smallest context. Good for quick experiments."
        case .balanced:
            return "Best speaker stability at about one second of latency."
        case .efficient:
            return "Higher throughput with about two seconds of output latency."
        }
    }

    var sortformerConfiguration: SortformerConfig {
        switch self {
        case .fast: return .fastV2_1
        case .balanced: return .balancedV2_1
        case .efficient: return .efficientV2_1
        }
    }
}

/// User-tunable diarization behavior. The model preset and the timeline
/// thresholds are read when a listening session starts.
nonisolated struct DiarizationTuning: Codable, Equatable, Sendable {
    var preset: DiarizationModelPreset = .balanced

    /// 0 = conservative, 1 = eager. Drives both onset and offset thresholds.
    var sensitivity: Double = 0.5

    /// Pauses shorter than this are merged into one speaker turn.
    var minGapSeconds: Double = 0

    /// Speech bursts shorter than this are discarded.
    var minSegmentSeconds: Double = 0

    /// How far away a speaker segment can be while still labeling a phrase.
    var labelGracePeriod: Double = 1.5

    var debugLogging: Bool = false

    static let `default` = DiarizationTuning()

    var timelineConfiguration: DiarizerTimelineConfig {
        var config = DiarizerTimelineConfig.sortformerDefault

        let clampedSensitivity = min(max(sensitivity, 0), 1)
        let threshold = Float(min(max(1 - clampedSensitivity, 0.1), 0.9))
        config.onsetThreshold = threshold
        config.offsetThreshold = threshold
        config.minDurationOn = Float(min(max(minSegmentSeconds, 0), 2))
        config.minDurationOff = Float(min(max(minGapSeconds, 0), 2))

        return config
    }

}

/// Captures microphone audio and resamples it to the 16 kHz mono Float32
/// format that FluidAudio's diarizers expect.
///
/// Audio taps run on a real-time thread, so this type is a small thread-safe
/// producer. `SpeakerDiarizationService` drains it from the main actor and
/// hands the samples to a background actor for inference.
nonisolated final class DiarizationAudioCapture: @unchecked Sendable {
    static let sampleRate: Double = 16_000

    private let lock = NSLock()
    private let outputFormat: AVAudioFormat
    private let maxPendingSamples = Int(DiarizationAudioCapture.sampleRate * 60 * 20)

    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var pending: [Float] = []
    private var readIndex = 0
    private var enabled = false

    init() {
        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    var isEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return enabled
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            enabled = newValue
        }
    }

    /// Starts a new audio stream. Called from the main actor before the tap is
    /// installed so the first buffer is not missed.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        pending.removeAll(keepingCapacity: false)
        readIndex = 0
        converter = nil
        sourceFormat = nil
    }

    /// Called from the audio render thread. Appends resampled samples while
    /// preserving the original stream's timeline.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard enabled, buffer.frameLength > 0 else { return }

        // Common fast path: the microphone already delivers the target format.
        if buffer.format.sampleRate == outputFormat.sampleRate,
           buffer.format.channelCount == 1,
           buffer.format.commonFormat == .pcmFormatFloat32,
           !buffer.format.isInterleaved,
           let samples = buffer.floatChannelData?[0] {
            appendLocked(samples, count: Int(buffer.frameLength))
            return
        }

        if sourceFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            sourceFormat = buffer.format
        }
        guard let converter else { return }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        // Extra headroom covers the resampler's filter delay so a single call
        // can consume the whole input buffer without dropping audio.
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio * 1.2).rounded(.up)) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }

        var conversionError: NSError?
        var suppliedInput = false
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard conversionError == nil,
              status != .error,
              output.frameLength > 0,
              let samples = output.floatChannelData?[0] else {
            return
        }

        appendLocked(samples, count: Int(output.frameLength))
    }

    /// Appends samples while the lock is held. The cap only applies if the
    /// model takes an extraordinarily long time to become ready; in normal use
    /// the background loop drains this buffer every 200 ms.
    private func appendLocked(_ samples: UnsafePointer<Float>, count: Int) {
        let unconsumed = pending.count - readIndex
        let room = max(0, maxPendingSamples - unconsumed)
        guard room > 0 else { return }

        pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: min(count, room)))

        // Reclaim the consumed prefix once it grows large so long sessions do
        // not keep every sample in memory.
        if readIndex > 1_000_000 {
            pending.removeFirst(readIndex)
            readIndex = 0
        }
    }

    /// Removes up to `maxSamples` from the front of the stream.
    func drain(maxSamples: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        let available = pending.count - readIndex
        guard available > 0, maxSamples > 0 else {
            if available <= 0 {
                pending.removeAll(keepingCapacity: true)
                readIndex = 0
            }
            return []
        }

        let count = min(available, maxSamples)
        let end = readIndex + count
        let samples = Array(pending[readIndex..<end])
        readIndex = end

        if readIndex == pending.count {
            pending.removeAll(keepingCapacity: true)
            readIndex = 0
        }
        return samples
    }
}

/// Owns the FluidAudio Sortformer model and confines all Core ML work to a
/// dedicated actor so the UI and audio threads stay responsive.
///
/// Sortformer is used because it keeps speaker identities stable across a
/// conversation and streams with roughly one second of latency. It supports
/// up to four simultaneous speakers.
actor SpeakerDiarizationEngine {
    private var models: SortformerModels?
    private var diarizer: SortformerDiarizer?

    private static func makeConfiguration(tuning: DiarizationTuning) -> SortformerConfig {
        var config = tuning.preset.sortformerConfiguration
        #if os(iOS) || os(visionOS)
        // The palettized build is about 100 MB instead of 250 MB and keeps
        // memory pressure low on phones, at a small accuracy cost.
        config.precision = .palettized
        #endif
        config.debugMode = tuning.debugLogging
        return config
    }

    func load(
        tuning: DiarizationTuning,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws {
        let config = Self.makeConfiguration(tuning: tuning)
        let models = try await SortformerModels.loadFromHuggingFace(
            config: config,
            progressHandler: onProgress
        )
        self.models = models
        makeDiarizer(config: config, tuning: tuning)
    }

    /// Recreates the streaming diarizer with new timeline thresholds and debug
    /// settings without downloading or recompiling the model. Only valid when
    /// the model preset is unchanged.
    func reconfigure(tuning: DiarizationTuning) {
        guard models != nil else { return }
        let config = Self.makeConfiguration(tuning: tuning)
        makeDiarizer(config: config, tuning: tuning)
    }

    private func makeDiarizer(config: SortformerConfig, tuning: DiarizationTuning) {
        guard let models else { return }
        diarizer?.cleanup()
        let diarizer = SortformerDiarizer(
            config: config,
            timelineConfig: tuning.timelineConfiguration
        )
        diarizer.initialize(models: models)
        self.diarizer = diarizer
    }

    /// Adds audio and processes every chunk that is ready, returning a full
    /// snapshot of the speaker timeline.
    func feed(_ samples: [Float]) throws -> [SpeakerSegment] {
        guard let diarizer else { return [] }

        if !samples.isEmpty {
            try diarizer.addAudio(samples, sourceSampleRate: nil)
        }
        while try diarizer.process() != nil {
            // Stopping listening should not wait for a long backlog to drain.
            // `finalizeSession()` finishes whatever remains.
            if Task.isCancelled { break }
        }

        return snapshot(of: diarizer)
    }

    /// Flushes the trailing audio when a listening session ends.
    func finish() throws -> [SpeakerSegment] {
        guard let diarizer else { return [] }
        _ = try diarizer.finalizeSession()
        return snapshot(of: diarizer)
    }

    func reset() {
        diarizer?.reset()
    }

    func release() {
        diarizer?.cleanup()
        diarizer = nil
        models = nil
    }

    private func snapshot(of diarizer: SortformerDiarizer) -> [SpeakerSegment] {
        let timeline = diarizer.timeline
        var segments: [SpeakerSegment] = []

        for speaker in timeline.speakers.values {
            for segment in speaker.finalizedSegments {
                segments.append(
                    SpeakerSegment(
                        speakerKey: segment.speakerIndex,
                        startTime: TimeInterval(segment.startTime),
                        endTime: TimeInterval(segment.endTime),
                        isFinalized: true
                    )
                )
            }
            for segment in speaker.tentativeSegments {
                segments.append(
                    SpeakerSegment(
                        speakerKey: segment.speakerIndex,
                        startTime: TimeInterval(segment.startTime),
                        endTime: TimeInterval(segment.endTime),
                        isFinalized: false
                    )
                )
            }
        }

        return segments.sorted {
            ($0.startTime, $0.endTime, $0.speakerKey)
                < ($1.startTime, $1.endTime, $1.speakerKey)
        }
    }
}

/// Coordinates model loading, streaming inference, and speaker-label lookup
/// for the transcript.
@MainActor
@Observable
final class SpeakerDiarizationService {
    private(set) var segments: [SpeakerSegment] = []
    private(set) var speakerNumbers: [Int: Int] = [:]
    private(set) var isPreparing = false
    private(set) var isRunning = false
    private(set) var isModelLoaded = false
    private(set) var isModelLoading = false
    private(set) var statusMessage = "Speaker labels off"
    private(set) var errorMessage: String?
    private(set) var downloadProgress: Double?

    @ObservationIgnored private let capture: DiarizationAudioCapture
    @ObservationIgnored private var engine: SpeakerDiarizationEngine?
    @ObservationIgnored private var loadTask: Task<SpeakerDiarizationEngine, Error>?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var timelineOffset: TimeInterval = 0
    @ObservationIgnored private var sessionKeyBase = 0
    @ObservationIgnored private var lastSpeakerKey: Int?
    @ObservationIgnored private var loadedPreset: DiarizationModelPreset?
    @ObservationIgnored private var sessionTuning: DiarizationTuning = .default

    /// Called whenever speaker segments change so the transcript can be
    /// re-rendered with updated labels.
    @ObservationIgnored var onSegmentsChanged: (() -> Void)?

    init(capture: DiarizationAudioCapture) {
        self.capture = capture
    }

    var hasSpeakers: Bool {
        !segments.isEmpty
    }

    /// Forgets all speaker labels. Used by the transcript's Clear button.
    func clearLabels() {
        segments = []
        speakerNumbers = [:]
        lastSpeakerKey = nil
        onSegmentsChanged?()
    }

    /// Starts collecting audio for a new listening session. The model load is
    /// kicked off separately so the caller can start transcription in parallel.
    @discardableResult
    func startCapture(
        enabled: Bool,
        timeOffset: TimeInterval,
        tuning: DiarizationTuning
    ) -> Int {
        generation += 1
        let sessionGeneration = generation

        sessionTuning = tuning
        processingTask?.cancel()
        processingTask = nil

        // Keep earlier segments and labels so transcript turns from previous
        // listening sessions stay attributed. New sessions use a fresh key
        // range and continue the speaker numbering.
        sessionKeyBase = sessionGeneration * 100
        lastSpeakerKey = nil
        errorMessage = nil
        downloadProgress = nil
        timelineOffset = timeOffset

        capture.reset()
        capture.isEnabled = enabled

        if enabled {
            isPreparing = true
            isRunning = false
            statusMessage = "Preparing speaker model…"
        } else {
            isPreparing = false
            isRunning = false
            statusMessage = isModelLoaded ? "Speaker labels ready" : "Speaker labels off"
        }

        onSegmentsChanged?()
        return sessionGeneration
    }

    /// Loads the model if necessary and starts the inference loop. Errors are
    /// surfaced without stopping speech transcription.
    func loadAndStartProcessing(generation sessionGeneration: Int) async {
        guard sessionGeneration == generation, capture.isEnabled else { return }

        let engine: SpeakerDiarizationEngine
        do {
            engine = try await loadEngine(tuning: sessionTuning)
        } catch {
            guard !Task.isCancelled, sessionGeneration == generation else { return }
            capture.isEnabled = false
            isPreparing = false
            isRunning = false
            downloadProgress = nil
            errorMessage = Self.message(for: error)
            statusMessage = "Speaker labels unavailable"
            return
        }

        guard !Task.isCancelled, sessionGeneration == generation else { return }

        await engine.reset()
        isPreparing = false
        isRunning = true
        downloadProgress = nil
        statusMessage = "Speaker labels on"
        startProcessingLoop(engine: engine, generation: sessionGeneration)
    }

    /// Loads the model once per app run. Concurrent listeners share the same
    /// in-flight load, and a load that outlives its session is kept so the next
    /// session starts instantly.
    ///
    /// Timeline/debug changes reuse the loaded model. A preset change releases
    /// the old engine and loads the new model bundle.
    private func loadEngine(tuning: DiarizationTuning) async throws -> SpeakerDiarizationEngine {
        // A previous session may still be downloading in the background.
        if let loadTask {
            _ = try? await loadTask.value
        }

        if let engine, loadedPreset == tuning.preset {
            await engine.reconfigure(tuning: tuning)
            return engine
        }

        if let engine {
            await engine.release()
            self.engine = nil
            loadedPreset = nil
            isModelLoaded = false
        }

        let onProgress: @Sendable (DownloadProgress) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.apply(progress)
            }
        }

        let task = Task { [weak self] () throws -> SpeakerDiarizationEngine in
            let newEngine = SpeakerDiarizationEngine()
            do {
                try await newEngine.load(tuning: tuning, onProgress: onProgress)
                if let self {
                    self.engine = newEngine
                    self.loadedPreset = tuning.preset
                    self.isModelLoaded = true
                    self.isModelLoading = false
                    self.loadTask = nil
                    self.statusMessage = self.isRunning
                        ? "Speaker labels on"
                        : "Speaker labels ready"
                }
                return newEngine
            } catch {
                await newEngine.release()
                if let self {
                    self.isModelLoading = false
                    self.loadTask = nil
                    if error is CancellationError {
                        self.statusMessage = "Speaker model not loaded yet"
                    } else {
                        self.errorMessage = Self.message(for: error)
                        self.statusMessage = "Speaker labels unavailable"
                    }
                }
                throw error
            }
        }
        loadTask = task
        isModelLoading = true
        errorMessage = nil
        if !isPreparing {
            statusMessage = "Loading speaker model…"
        }

        return try await task.value
    }

    /// Stops inference, flushes the final audio, and keeps the last labels on
    /// screen.
    func endSession() async {
        generation += 1
        let sessionGeneration = generation

        capture.isEnabled = false

        let task = processingTask
        processingTask = nil
        task?.cancel()
        if let task {
            await task.value
        }

        guard let engine else {
            isPreparing = false
            isRunning = false
            downloadProgress = nil
            if errorMessage == nil {
                statusMessage = isModelLoaded ? "Speaker labels ready" : "Speaker labels off"
            }
            return
        }

        do {
            let remaining = capture.drain(maxSamples: Int.max)
            if !remaining.isEmpty {
                _ = try await engine.feed(remaining)
            }
            let finalSegments = try await engine.finish()
            if sessionGeneration == generation {
                apply(finalSegments)
            }
        } catch {
            guard sessionGeneration == generation else { return }
            record(error)
        }

        await engine.reset()
        isPreparing = false
        isRunning = false
        downloadProgress = nil
        if errorMessage == nil {
            statusMessage = "Speaker labels ready"
        }
    }

    /// Releases the loaded model and deletes FluidAudio's Sortformer cache so
    /// the next session downloads and compiles it again.
    func clearModelCache() async {
        guard !isRunning, !isPreparing, !isModelLoading else { return }

        if let engine {
            await engine.release()
        }
        engine = nil
        loadedPreset = nil
        isModelLoaded = false
        downloadProgress = nil
        errorMessage = nil
        statusMessage = "Speaker model not loaded yet"

        let directory = Self.modelCacheDirectory()
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }.value
    }

    private static func modelCacheDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/sortformer", isDirectory: true)
    }

    /// Returns the diarizer slot that overlaps `range` the most.
    ///
    /// When diarization has not caught up with a phrase yet, the nearest
    /// segment is used, then the most recent speaker as a final fallback.
    func speakerSlot(for range: ClosedRange<TimeInterval>) -> Int? {
        guard !segments.isEmpty else { return nil }

        var best: (slot: Int, overlap: TimeInterval, finalized: Bool)?
        for segment in segments {
            let overlap = min(range.upperBound, segment.endTime)
                - max(range.lowerBound, segment.startTime)
            guard overlap > 0 else { continue }

            if let current = best {
                if overlap > current.overlap
                    || (overlap == current.overlap && segment.isFinalized && !current.finalized) {
                    best = (segment.speakerKey, overlap, segment.isFinalized)
                }
            } else {
                best = (segment.speakerKey, overlap, segment.isFinalized)
            }
        }
        if let best {
            return best.slot
        }

        // Turns from an earlier listening session that have no matching
        // segment should stay unlabeled rather than borrowing the current
        // session's speaker.
        if range.upperBound <= timelineOffset {
            return nil
        }

        let midpoint = (range.lowerBound + range.upperBound) / 2
        let nearest = segments.min { gap(from: $0, to: midpoint) < gap(from: $1, to: midpoint) }
        let gracePeriod = min(max(sessionTuning.labelGracePeriod, 0), 5)
        if let nearest, gap(from: nearest, to: midpoint) <= gracePeriod {
            return nearest.speakerKey
        }
        return lastSpeakerKey
    }

    func speakerNumber(for slot: Int) -> Int? {
        speakerNumbers[slot]
    }

    private func startProcessingLoop(
        engine: SpeakerDiarizationEngine,
        generation sessionGeneration: Int
    ) {
        processingTask = Task { [weak self] in
            let maxChunkSamples = Int(DiarizationAudioCapture.sampleRate * 10)

            while !Task.isCancelled {
                guard let self, self.generation == sessionGeneration else { return }

                let samples = self.capture.drain(maxSamples: maxChunkSamples)
                if samples.isEmpty {
                    try? await Task.sleep(for: .milliseconds(200))
                    continue
                }

                do {
                    let snapshot = try await engine.feed(samples)
                    guard !Task.isCancelled, self.generation == sessionGeneration else { return }
                    self.apply(snapshot)
                } catch {
                    guard !Task.isCancelled, self.generation == sessionGeneration else { return }
                    self.record(error)
                    return
                }
            }
        }
    }

    private func apply(_ progress: DownloadProgress) {
        guard isPreparing || isModelLoading else { return }
        downloadProgress = progress.fractionCompleted

        switch progress.phase {
        case .listing:
            statusMessage = "Checking speaker model…"
        case .downloading(let completedFiles, let totalFiles):
            if totalFiles > 0 {
                statusMessage = "Downloading speaker model… \(completedFiles)/\(totalFiles)"
            } else {
                statusMessage = "Downloading speaker model…"
            }
        case .compiling:
            statusMessage = "Compiling speaker model…"
        }
    }

    private func apply(_ newSegments: [SpeakerSegment]) {
        let shifted = newSegments.map {
            SpeakerSegment(
                speakerKey: sessionKeyBase + $0.speakerKey,
                startTime: $0.startTime + timelineOffset,
                endTime: $0.endTime + timelineOffset,
                isFinalized: $0.isFinalized
            )
        }

        var numbers = speakerNumbers
        for segment in shifted where numbers[segment.speakerKey] == nil {
            numbers[segment.speakerKey] = (numbers.values.max() ?? 0) + 1
        }

        // Keep segments from earlier sessions, replace only this session's
        // snapshot, and sort the combined timeline.
        let previous = segments.filter { $0.speakerKey < sessionKeyBase }
        let merged = (previous + shifted).sorted {
            ($0.startTime, $0.endTime, $0.speakerKey)
                < ($1.startTime, $1.endTime, $1.speakerKey)
        }

        let changed = merged != segments || numbers != speakerNumbers
        segments = merged
        speakerNumbers = numbers
        if let last = shifted.last {
            lastSpeakerKey = last.speakerKey
        }

        if changed {
            onSegmentsChanged?()
        }
    }

    private func record(_ error: Error) {
        capture.isEnabled = false
        isRunning = false
        isPreparing = false
        downloadProgress = nil
        errorMessage = Self.message(for: error)
        statusMessage = "Speaker labels unavailable"
    }

    private func gap(from segment: SpeakerSegment, to time: TimeInterval) -> TimeInterval {
        if time < segment.startTime { return segment.startTime - time }
        if time > segment.endTime { return time - segment.endTime }
        return 0
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

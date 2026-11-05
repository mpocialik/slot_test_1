# AGENTS.md

Single-target SwiftUI app ("Foundation Model Tester") that transcribes live
speech on-device (`SpeechAnalyzer` / `SpeechTranscriber`) and streams it to
Apple's on-device Foundation Model (`SystemLanguageModel`), with optional
speaker diarization via FluidAudio.

## Build & run

- Requires **Xcode 27.3+**. The project uses the Xcode 27 **`.xcproj` JSON
  format** — there is **no `project.pbxproj`**. Build settings live in
  `slot_test_1.xcodeproj/project.xcproj`.
- Open `slot_test_1.xcodeproj`, select the `slot_test_1` scheme, run on an
  iPhone/iPad simulator. The simulator uses the Mac's microphone; allow
  Microphone and Speech Recognition on first run.
- **No test target, CI, lint, or formatter config.** Verification is running
  the app. There is no `Package.swift` either (SwiftPM is wired through Xcode).
- This machine has only CommandLineTools active (`xcode-select -p`), so
  `xcodebuild` is unavailable — build from the Xcode GUI.

## Architecture

- `MyApp.swift` — `@main` entrypoint.
- `ContentView.swift` — all UI in one file.
- `TesterViewModel.swift` — `@MainActor @Observable` orchestrator: owns the
  transcriber and model client, owns the committed ledger, tracks the finalized
  transcript cursor, and runs the auto-send timer loop.
- `DefaultSystemPrompt.md` — the built-in system prompt. It defines the
  two-block ledger contract (`PREVIOUS LEDGER` + `NEW TRANSCRIPT`). Loaded from
  the app bundle at launch (`TesterViewModel.defaultInstructions`), so edit this
  file instead of Swift source to change the default. An inline copy in
  `TesterViewModel.swift` is only the fallback if the resource is missing.
- `LiveSpeechTranscriber.swift` — `AVAudioEngine` mic capture + live
  transcription; also owns the diarization capture. Exposes finalized turns by
  index so the view model can consume each batch once.
- `SpeakerDiarization.swift` — FluidAudio Sortformer diarization
  (`DiarizationAudioCapture`, `SpeakerDiarizationEngine` actor,
  `SpeakerDiarizationService`) and speaker-label lookup.
- `FoundationModelClient.swift` — stateless ledger updater: sends
  `previous ledger + new transcript` to `SystemLanguageModel` and streams back
  the complete updated ledger. No session history is retained. It also keeps an
  in-memory `LLMCallRecord` log (prompts, outputs, errors) for the History
  screen; that log is intentionally not persisted.

Audio flow: one `installTap` feeds both the speech analyzer (via
`AnalyzerInputConverter`) and `DiarizationAudioCapture`, which resamples to
16 kHz mono Float32. The tap runs on a real-time thread; `DiarizationAudioCapture`
is a thread-safe producer drained by `SpeakerDiarizationService` on the main
actor, which forwards samples to the engine actor for inference.

## Conventions & gotchas

- **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** (in `project.xcproj`): types
  are `@MainActor` by default; opt out with `nonisolated`. This is why
  `SpeakerSegment`, `DiarizationTuning`, and the enum types in
  `SpeakerDiarization.swift` are `nonisolated`.
- Multi-platform target: `iphoneos iphonesimulator macosx xros xrsimulator`
  (iOS 27.3+ / macOS 27.2+). Code branches on `#if os(macOS)` vs
  `#if os(iOS) || os(visionOS)`.
- **Only dependency**: `FluidAudio` 0.18.2 (SwiftPM, pinned in
  `Package.resolved`, trait `Diarizer`). Speaker models download at runtime
  from Hugging Face and cache under Application Support
  `FluidAudio/Models/sortformer` (~100 MB palettized on iOS, ~250 MB fp16 on
  macOS). No other network access.
- Everything is on-device; there are no API keys or remote services. Model
  responses require Apple Intelligence (transcription works without it).
  Reasoning levels are ignored by the on-device model (`SystemLanguageModel`
  lacks the `.reasoning` capability) — see `FoundationModelClient.swift`.
- Persisted settings use `UserDefaults` keys `systemInstructions`,
  `speakerLabelsEnabled`, `diarizationTuning` (JSON), and `runningLedger` (the
  committed ledger, cleared by **Clear**). `systemInstructions`
  is only written when the text differs from the bundled default, so a rebuild
  after editing `DefaultSystemPrompt.md` is picked up unless the user typed a
  custom prompt (**Reset to default** clears it).
- Model-call history (`LLMCallRecord`) is in-memory only, held by
  `FoundationModelClient.history`. It is not a `UserDefaults` key and is lost
  when the app exits.
- Signing is already configured: automatic, `DEVELOPMENT_TEAM = XHV2GLB6KY`,
  bundle id `com.michaelpocialikpersonalteam.slottest1`.

## Reference

`README.md` documents behavior and tuning in detail (speaker modes, diarization
tuning, latency sliders). Read it before changing UI-facing behavior.

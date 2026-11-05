# Foundation Model Tester

A small SwiftUI app that turns live speech into text and sends that text to
Apple's on-device Foundation Model.

## What it does

- Captures the microphone with `AVAudioEngine`.
- Transcribes speech live on device with `SpeechAnalyzer` / `SpeechTranscriber`.
- Labels who is speaking with on-device diarization from
  [FluidAudio](https://github.com/FluidInference/FluidAudio) (NVIDIA Sortformer),
  rendering turns as “Speaker 1”, “Speaker 2”, and so on. Up to four speakers.
- Shows volatile (in-progress) words as they are recognized and commits final results.
- Lets you tune transcription speed with fast speech results and an artificial display lag.
- Lets you tune model speed with a reasoning level and an artificial streaming lag.
- Folds each batch of finalized speech into a running medical ledger every 5 seconds (configurable from 1–15 seconds).
- Keeps the ledger as the conversation state, so earlier speech and replies survive without an unbounded session history.
- Streams the model's response back to the screen token by token.
- Logs every model call for the current app session so you can inspect the exact
  system instructions, user prompt, output, and failures.
- Provides "Send Now", "Clear", copy buttons, and editable system instructions
  that persist across launches.

Audio is never sent off the device. The transcript is passed only to Apple's
on-device Foundation Model. Speaker diarization also runs locally through
Core ML.

## Speaker labels

The app feeds the same microphone audio to two on-device pipelines: Apple's
`SpeechAnalyzer` for words and FluidAudio's streaming Sortformer diarizer for
“who spoke when”. Final words are attributed to the speaker with the largest
time overlap, and labels are refreshed as the diarizer catches up, so a phrase
may gain its speaker label a moment after it appears.

Sortformer is optimized for conversations and supports up to four speakers.
It runs through Core ML on the Neural Engine where available. Diarization is
best-effort: if the model cannot load, transcription continues without labels.

The default **Exactly 2** mode ranks the diarizer's four slots by total speech
per session, keeps the top two, and folds stray slots into the nearest of
those two. Switch to **Auto (up to 4)** in tuning if you want the native
four-slot behavior.

Transcription is always handled by Apple's `SpeechAnalyzer` /
`SpeechTranscriber`. FluidAudio is used only to compute speaker labels.
Turning **Speaker labels** off hides the labels immediately and starts no
FluidAudio work for subsequent listening sessions; Apple's transcription
pipeline is unaffected. A model already loaded from an earlier session stays
cached in memory so a later restart is fast.

### Diarization tuning

**Configuration → Diarization tuning** exposes the knobs that are useful for
experimenting without touching code:

- **Speaker count** — Exactly 2 (default) or Auto (up to 4). Exactly 2 keeps
  the two speaker slots with the most speech in each session, merges stray
  slots into the nearest of those two, and reuses Speaker 1/2 across sessions
  so the whole transcript stays at two labels.
- **Model preset** — Fast, Balanced (default), or Efficient. Changing the
  preset loads the matching model bundle on the next session (downloading it
  the first time).
- **Speaker sensitivity** — drives the Sortformer onset/offset thresholds.
  Higher reacts sooner to speaker changes; lower is more conservative.
- **Merge pauses under** — closes short gaps between same-speaker segments.
- **Ignore blips under** — discards very short speech bursts.
- **Label grace period** — how far away a speaker segment can be while still
  labeling a phrase in the transcript.
- **Debug logging** — extra FluidAudio diagnostics in the console.
- **Reset to defaults** and **Clear cached model** — the latter deletes the
  downloaded Sortformer bundle and forces a fresh download next time.

Tuning values persist in `UserDefaults` and apply when you next start
listening. Timeline-only changes reuse the loaded model; changing the preset
loads a different model.

## System instructions

The built-in system prompt lives in
[`slot_test_1/DefaultSystemPrompt.md`](slot_test_1/DefaultSystemPrompt.md) as
plain Markdown, so it can be edited in any text editor without opening Xcode.
The app reads the file from its bundle at launch, so edits take effect on the
next build and run.

Text typed into **Configuration → System instructions** is saved in
`UserDefaults` and overrides the file. **Reset to default** discards that
custom text and goes back to the version currently in the bundle. If the file
is missing or empty, the app falls back to an inline copy of the prompt in
`TesterViewModel.swift`.

The default prompt is the medical-scribe ledger contract. The client always
wraps input as `PREVIOUS LEDGER` and `NEW TRANSCRIPT`, so a custom prompt should
keep that two-block shape if it wants to use the running ledger as state.

## Running ledger

The ledger is the only model workload. Each update is a stateless request:

```
previous ledger + new finalized speech -> updated ledger
```

No `LanguageModelSession` history is carried between updates. The ledger itself
is the state, so it stays bounded, can be inspected, and survives an ASR
revision or a context overflow.

Behavior worth knowing:

- Only **finalized** speech is sent. Volatile words stay on screen but never
  enter the ledger, so a revised partial result cannot corrupt the state.
- The transcript cursor advances only after a successful update. If the model
  errors or the request is interrupted, the same speech is retried next tick.
- `Send Now` flushes pending finalized speech and does not re-send anything
  already folded in.
- If the ledger grows past roughly 6,000 characters, a separate compaction turn
  shortens it while preserving every fact and tag. An update that loses a large
  share of the existing bullets is rejected once and retried with a preservation
  reminder.
- The ledger is persisted in `UserDefaults` (`runningLedger`) so a crash or a
  backgrounded call does not lose it. **Clear** starts a new call and resets it.

Because the default prompt asks for the complete ledger on every turn, the
cadence is a real tradeoff: a 10–15 second interval keeps the per-update prompt
smaller and is usually enough for a scribe that is reviewed after the call.

## Call history

The **History** button opens a list of every request sent to the model during
the app session. Each row shows the call type, time, duration, status, and a
preview. Opening a call shows:

- The exact system instructions and user prompt strings passed to
  `LanguageModelSession`.
- The streamed output (or the partial output if the call was cancelled).
- Any retry note or error message.
- Copy actions for the full request, the user prompt, and the output.

The log includes ledger updates, retries, and ledger-compaction calls, and it is
kept in memory only. It is not written to `UserDefaults` and disappears when the
app quits. **Clear** in the history screen empties it; the main **Clear** button
does not, so starting a new call leaves the previous call's calls inspectable
until the app exits.

## Requirements

- Xcode 27.3 or later.
- iOS 27.3+ (iPhone or iPad) or macOS 27.2+.
- Apple Intelligence enabled for model responses (live transcription works without it).
- Microphone and Speech Recognition permissions.

The first launch may download the speech transcription model. Speaker labels
also download a one-time diarization model (roughly 100 MB on iPhone/iPad,
250 MB on Mac) and cache it in Application Support. `Foundation Model Tester`
requests microphone and speech recognition access when you tap **Start
Listening**.

Speaker labels are on by default. You can turn them off in **Configuration →
Speaker labels** to skip the diarization model download.

## Run on iOS

The target is already configured for iPhone and iPad (`SUPPORTED_PLATFORMS`
includes `iphoneos` and `iphonesimulator`).

1. Open `slot_test_1.xcodeproj` in Xcode.
2. Select the `slot_test_1` scheme.
3. Pick an iPhone or iPad simulator, then press **Run**.
4. To run on a physical device, select your iPhone/iPad and choose your
   development team under **Signing & Capabilities** (Automatic signing works
   for a free Apple ID).

The simulator uses your Mac's microphone. On first run, allow Microphone and
Speech Recognition access.

The app icon in `Assets.xcassets/AppIcon.appiconset` supplies the iOS 1024×1024
icon plus the macOS sizes.

## Project notes

The project uses the Xcode 27 `.xcproj` format. Relevant privacy and sandbox
settings are already in the target:

- `NSMicrophoneUsageDescription`
- `NSSpeechRecognitionUsageDescription`
- `com.apple.security.device.audio-input` (macOS App Sandbox audio input)
- Outgoing network access for the one-time speech and speaker-model downloads

Speaker models are cached in the app's Application Support directory by
FluidAudio, so the download happens once per install/device (and per model
precision: palettized on iOS, fp16 on macOS).

## Files

- `ContentView.swift` — UI
- `TesterViewModel.swift` — ledger state, send loop, speed settings, and app state
- `LiveSpeechTranscriber.swift` — microphone capture and live transcription
- `SpeakerDiarization.swift` — FluidAudio Sortformer speaker labels
- `FoundationModelClient.swift` — stateless ledger updates through Foundation Models

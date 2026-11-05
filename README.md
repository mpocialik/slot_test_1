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
- Sends the newest transcript to a `LanguageModelSession` every 5 seconds (configurable from 1–15 seconds).
- Lets you tune LLM speed with a reasoning level and an artificial streaming lag.
- Optionally keeps earlier transcripts and model replies in conversation context.
- Streams the model's response back to the screen token by token.
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
- `TesterViewModel.swift` — send loop, speed settings, and app state
- `LiveSpeechTranscriber.swift` — microphone capture and live transcription
- `SpeakerDiarization.swift` — FluidAudio Sortformer speaker labels
- `FoundationModelClient.swift` — streaming Foundation Models client

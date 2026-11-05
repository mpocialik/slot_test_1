# Foundation Model Tester

A small SwiftUI app that turns live speech into text and sends that text to
Apple's on-device Foundation Model.

## What it does

- Captures the microphone with `AVAudioEngine`.
- Transcribes speech live on device with `SpeechAnalyzer` / `SpeechTranscriber`.
- Shows volatile (in-progress) words as they are recognized and commits final results.
- Sends the newest transcript to a `LanguageModelSession` every 5 seconds (configurable from 1–15 seconds).
- Streams the model's response back to the screen token by token.
- Provides "Send Now", "Clear", copy buttons, and editable system instructions.

Audio is never sent off the device. The transcript is passed only to Apple's
on-device Foundation Model.

## Requirements

- Xcode 27.3 or later.
- iOS 27.3+ (iPhone or iPad) or macOS 27.2+.
- Apple Intelligence enabled for model responses (live transcription works without it).
- Microphone and Speech Recognition permissions.

The first launch may download the speech transcription model. `Foundation Model
Tester` requests microphone and speech recognition access when you tap **Start
Listening**.

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
- Outgoing network access for the one-time speech asset download

## Files

- `ContentView.swift` — UI
- `TesterViewModel.swift` — 5-second send loop and app state
- `LiveSpeechTranscriber.swift` — microphone capture and live transcription
- `FoundationModelClient.swift` — streaming Foundation Models client

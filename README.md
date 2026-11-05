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

- Xcode 27 or Swift Playgrounds on macOS 27.2+, or an iOS 27.3+ device.
- Apple Intelligence enabled for model responses (live transcription works without it).
- Microphone and Speech Recognition permissions.

The first launch may download the speech transcription model. `Foundation Model
Tester` requests microphone and speech recognition access when you tap **Start
Listening**.

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

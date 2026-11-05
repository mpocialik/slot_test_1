import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ContentView: View {
    @State private var tester = TesterViewModel()
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusRow

                if !tester.model.isAvailable {
                    modelUnavailableNotice
                }

                if let error = tester.errorMessage {
                    errorBanner(error)
                }

                controls
                transcriptPanel
                responsePanel
                configurationPanel
                footer
            }
            .padding(20)
            .frame(maxWidth: 840)
            .frame(maxWidth: .infinity)
        }
        .background(background)
        .onAppear {
            tester.refreshModelAvailability()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                Task { await tester.stopListening() }
            } else if phase == .active {
                tester.refreshModelAvailability()
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 58, height: 58)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("Foundation Model Tester")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)

                Text("Live on-device speech → Apple Foundation Models")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            StatusPill(
                text: tester.model.availabilityText,
                systemImage: "cpu",
                color: tester.model.isAvailable ? .green : .orange
            )

            StatusPill(
                text: tester.transcriber.statusMessage,
                systemImage: "mic.fill",
                color: statusColor
            )

            Spacer(minLength: 0)

            Label("On device", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                primaryButton
                sendButton(compact: false)
                clearButton(compact: false)
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                primaryButton
                sendButton(compact: true)
                clearButton(compact: true)
                Spacer(minLength: 0)
            }
        }
    }

    private var primaryButton: some View {
        Button {
            Task {
                if tester.isListening {
                    await tester.stopListening()
                } else {
                    await tester.startListening()
                }
            }
        } label: {
            HStack(spacing: 8) {
                if tester.isPreparing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: tester.isListening ? "stop.fill" : "mic.fill")
                }

                Text(tester.isListening ? "Stop Listening" : "Start Listening")
                    .lineLimit(1)
            }
            .frame(minWidth: 136)
        }
        .buttonStyle(.borderedProminent)
        .tint(tester.isListening ? .red : .accentColor)
        .controlSize(.large)
        .disabled(tester.isPreparing)
    }

    private func sendButton(compact: Bool) -> some View {
        Button {
            tester.sendNow()
        } label: {
            if compact {
                Image(systemName: "paperplane.fill")
            } else {
                Label("Send Now", systemImage: "paperplane.fill")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(!tester.canSendNow || tester.isPreparing)
        .accessibilityLabel("Send transcript now")
    }

    private func clearButton(compact: Bool) -> some View {
        Button(role: .destructive) {
            tester.clear()
        } label: {
            if compact {
                Image(systemName: "trash")
            } else {
                Label("Clear", systemImage: "trash")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(tester.transcript.isEmpty && tester.modelOutput.isEmpty && !tester.isResponding)
        .accessibilityLabel("Clear transcript and response")
    }

    private var transcriptPanel: some View {
        PanelCard(
            title: "Live Transcript",
            systemImage: "text.bubble",
            showsActivity: tester.isListening,
            copyText: tester.transcript
        ) {
            if tester.transcript.isEmpty {
                Text(tester.isListening
                     ? "Listening… start speaking."
                     : "Tap Start Listening and speak. Your words will appear here in real time.")
                    .foregroundStyle(.secondary)
            } else {
                Text(tester.transcript)
                    .textSelection(.enabled)
            }
        }
        .frame(minHeight: 150, alignment: .top)
    }

    private var responsePanel: some View {
        PanelCard(
            title: "Foundation Model Response",
            systemImage: "sparkles",
            showsProgress: tester.isResponding,
            copyText: tester.modelOutput
        ) {
            if tester.modelOutput.isEmpty {
                Text(tester.isResponding
                     ? "Thinking…"
                     : responsePlaceholder)
                    .foregroundStyle(.secondary)
            } else {
                Text(tester.modelOutput)
                    .textSelection(.enabled)
            }
        }
        .frame(minHeight: 170, alignment: .top)
    }

    private var configurationPanel: some View {
        ConfigurationPanel(tester: tester, isExpanded: $showSettings)
    }

    private var footer: some View {
        Label(
            "Speech is transcribed on device. Transcripts are processed only by Apple's on-device foundation model.",
            systemImage: "lock.shield"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private var modelUnavailableNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.orange)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text("Foundation Models is unavailable")
                    .font(.callout.weight(.semibold))
                Text("\(tester.model.availabilityText). Live transcription still works. Enable Apple Intelligence to test model responses.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)

                if tester.needsPermissionSettings, let url = systemSettingsURL {
                    Button("Open Settings") {
                        openURL(url)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var background: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.12), Color.clear],
            startPoint: .top,
            endPoint: .center
        )
        .background(Color.primary.opacity(0.015))
        .ignoresSafeArea()
    }

    // MARK: - Helpers

    private var statusColor: Color {
        if tester.isPreparing {
            return .blue
        }
        if tester.transcriber.errorMessage != nil {
            return .orange
        }
        return tester.isListening ? .green : .secondary
    }

    private var responsePlaceholder: String {
        if tester.autoSendEnabled {
            return "The newest transcript is sent to the model automatically every \(Int(tester.cadenceSeconds)) seconds."
        }
        return "Tap Send Now to send the current transcript to the model."
    }

    private var systemSettingsURL: URL? {
        #if os(macOS)
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")
        #else
        URL(string: UIApplication.openSettingsURLString)
        #endif
    }
}

// MARK: - Components

private struct ConfigurationPanel: View {
    @Bindable var tester: TesterViewModel
    @Binding var isExpanded: Bool

    var body: some View {
        PanelCard(title: "Configuration", systemImage: "slider.horizontal.3") {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 20) {
                    transcriptionSpeedSection
                    Divider()
                    llmSpeedSection
                    Divider()
                    conversationSection
                    Divider()
                    instructionsSection
                }
                .padding(.top, 10)
            } label: {
                Text("Speed, memory, and model instructions")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var transcriptionSpeedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Transcription speed", systemImage: "waveform")
                .font(.subheadline.weight(.semibold))

            Text("Speech results")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Speech results", selection: $tester.fastTranscription) {
                Text("Fast").tag(true)
                Text("Balanced").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("Fast results appear sooner but may be less accurate. Applies the next time you start listening.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text("Display lag")
                    .frame(width: 82, alignment: .leading)

                Slider(value: $tester.transcriptionLatencyMilliseconds, in: 0...1_000, step: 50)

                Text("\(Int(tester.transcriptionLatencyMilliseconds)) ms")
                    .monospacedDigit()
                    .frame(width: 54, alignment: .trailing)
            }

            Text("Artificial delay before new transcript text appears. 0 ms is real time.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var llmSpeedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("LLM speed", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))

            Text("Reasoning level")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Reasoning level", selection: $tester.reasoningLevel) {
                ForEach(ModelReasoningLevel.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(tester.reasoningLevel.summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text("Stream lag")
                    .frame(width: 82, alignment: .leading)

                Slider(value: $tester.llmStreamLatencyMilliseconds, in: 0...300, step: 25)

                Text("\(Int(tester.llmStreamLatencyMilliseconds)) ms")
                    .monospacedDigit()
                    .frame(width: 54, alignment: .trailing)
            }

            Text("Artificial delay between streamed model updates. 0 ms is as fast as the model can respond.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(isOn: $tester.autoSendEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send automatically")
                    Text("Sends the newest transcript to the model on a timer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Text("Send every")
                    .frame(width: 82, alignment: .leading)

                Slider(value: $tester.cadenceSeconds, in: 1...15, step: 1)

                Text("\(Int(tester.cadenceSeconds)) s")
                    .monospacedDigit()
                    .frame(width: 54, alignment: .trailing)
            }
            .disabled(!tester.autoSendEnabled)
            .opacity(tester.autoSendEnabled ? 1 : 0.5)
        }
    }

    private var conversationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Conversation", systemImage: "bubble.left.and.bubble.right")
                .font(.subheadline.weight(.semibold))

            Toggle(isOn: $tester.conversationMemoryEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Conversation memory")
                    Text("Keeps earlier transcripts and model replies in context. Off sends each request independently.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Toggling memory or pressing Clear starts a fresh conversation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("System instructions")
                .font(.subheadline.weight(.semibold))

            TextEditor(text: $tester.instructions)
                .font(.callout)
                .frame(height: 110)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
        }
    }
}

private struct StatusPill: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)

            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.12), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(color.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct PanelCard<Content: View>: View {
    let title: String
    let systemImage: String
    let showsActivity: Bool
    let showsProgress: Bool
    let copyText: String?
    let content: Content

    init(
        title: String,
        systemImage: String,
        showsActivity: Bool = false,
        showsProgress: Bool = false,
        copyText: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.showsActivity = showsActivity
        self.showsProgress = showsProgress
        self.copyText = copyText
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.headline)

                Spacer(minLength: 0)

                if showsActivity {
                    PulsingDot()
                }

                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                }

                if let copyText, !copyText.isEmpty {
                    Button {
                        copyToClipboard(copyText)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Copy text")
                    .accessibilityLabel("Copy \(title)")
                }
            }

            Divider()

            content
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .textSelection(.enabled)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }
}

private struct PulsingDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(.green)
            .frame(width: 8, height: 8)
            .overlay {
                Circle()
                    .stroke(.green.opacity(0.5), lineWidth: 1)
                    .scaleEffect(pulsing ? 2.4 : 1)
                    .opacity(pulsing ? 0 : 1)
            }
            .onAppear {
                withAnimation(.easeOut(duration: 1).repeatForever(autoreverses: false)) {
                    pulsing = true
                }
            }
            .accessibilityLabel("Live")
    }
}

private func copyToClipboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}

#Preview {
    ContentView()
}

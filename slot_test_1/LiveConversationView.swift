import Foundation
import SwiftUI

/// Full-screen, karaoke-style presentation of the live transcript.
///
/// The most recent line stays centered and bright while earlier lines fade
/// into the background. The in-progress line highlights word by word, and
/// speaker changes get a small colored label above the line.
struct LiveConversationView: View {
    let tester: TesterViewModel

    @Environment(\.dismiss) private var dismiss

    private var lines: [TimedTranscriptLine] {
        tester.transcriptLines
    }

    private var activeLineID: UUID? {
        lines.last?.id
    }

    private var activeSpeakerNumber: Int? {
        lines.last?.speakerNumber
    }

    private var accentColor: Color {
        ConversationPalette.color(for: activeSpeakerNumber)
    }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                topBar

                GeometryReader { splitGeometry in
                    let halfHeight = max(0, (splitGeometry.size.height - 1) / 2)

                    VStack(spacing: 0) {
                        conversationScroll(viewportHeight: halfHeight)
                            .frame(height: halfHeight)

                        Rectangle()
                            .fill(.white.opacity(0.08))
                            .frame(height: 1)

                        ledgerSection
                            .frame(height: halfHeight)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }

                bottomBar
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close conversation")

            Spacer(minLength: 0)

            VStack(spacing: 3) {
                Text("LIVE CONVERSATION")
                    .font(.caption2.weight(.bold))
                    .tracking(1.8)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(headerStatus)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 0)

            Image(systemName: tester.speakerLabelsEnabled ? "person.2.wave.2.fill" : "waveform")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accentColor.opacity(0.9))
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.08), in: Circle())
                .accessibilityLabel(tester.speakerLabelsEnabled ? "Speaker labels on" : "Speaker labels off")
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private var headerStatus: String {
        if tester.isPreparing {
            return tester.transcriber.statusMessage
        }
        if tester.isListening {
            return "Listening live"
        }
        return lines.isEmpty ? "Not listening" : "Paused"
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let error = tester.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 24)
            }

            HStack(spacing: 14) {
                Button {
                    Task {
                        if tester.isListening {
                            await tester.stopListening()
                        } else {
                            await tester.startListening()
                        }
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(.white)

                        if tester.isPreparing {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.black)
                        } else {
                            Image(systemName: tester.isListening ? "pause.fill" : "mic.fill")
                                .font(.system(size: 19, weight: .bold))
                                .foregroundStyle(.black)
                        }
                    }
                    .frame(width: 54, height: 54)
                }
                .buttonStyle(.plain)
                .disabled(tester.isPreparing)
                .accessibilityLabel(tester.isListening ? "Stop listening" : "Start listening")

                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))

                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Button {
                    tester.sendNow()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(canSend ? 0.85 : 0.3))
                        .frame(width: 42, height: 42)
                        .background(.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send pending speech to the ledger")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.white.opacity(0.07), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
    }

    private var canSend: Bool {
        tester.canSendNow && !tester.isPreparing
    }

    private var statusTitle: String {
        if tester.isPreparing {
            return "Getting ready…"
        }
        return tester.isListening ? "Listening live" : "Paused"
    }

    private var statusDetail: String {
        if tester.isResponding {
            return "Updating the running ledger…"
        }
        if tester.isPreparing {
            return tester.transcriber.statusMessage
        }
        if tester.isListening {
            return lineCountText
        }
        return lines.isEmpty ? "Tap the microphone to start" : "\(lineCountText) · Tap to resume"
    }

    private var lineCountText: String {
        "\(lines.count) line\(lines.count == 1 ? "" : "s") captured"
    }

    // MARK: - Conversation

    private func conversationScroll(viewportHeight: CGFloat) -> some View {
        let verticalInset = max(32, viewportHeight * 0.38)

        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 12) {
                    if lines.isEmpty {
                        emptyState
                            .frame(minHeight: max(0, viewportHeight - 16))
                    } else {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                            ConversationLineRow(
                                line: line,
                                isActive: line.id == activeLineID,
                                showsSpeaker: line.speakerNumber != nil
                                    && line.speakerNumber != previousSpeaker(before: index),
                                isLive: tester.isListening && !line.isFinal
                            )
                            .id(line.id)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, lines.isEmpty ? 0 : verticalInset)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.10),
                        .init(color: .black, location: 0.90),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .onAppear {
                scrollToActive(proxy, animated: false)
            }
            .task {
                // Let the first layout settle before jumping to a long
                // transcript's newest line.
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
                scrollToActive(proxy, animated: false)
            }
            .onChange(of: activeLineID) { _, _ in
                scrollToActive(proxy, animated: true)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: tester.isListening ? "waveform" : "bubble.left.and.bubble.right")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.white.opacity(0.38))

            Text(tester.isListening ? "Listening…" : "No conversation yet")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))

            Text(tester.isListening
                 ? "Start speaking and your words will scroll here."
                 : "Tap the microphone at the bottom to start listening.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func previousSpeaker(before index: Int) -> Int? {
        guard index > 0 else { return nil }
        return lines[index - 1].speakerNumber
    }

    private func scrollToActive(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let activeLineID else { return }

        if animated {
            withAnimation(.easeInOut(duration: 0.55)) {
                proxy.scrollTo(activeLineID, anchor: .center)
            }
        } else {
            proxy.scrollTo(activeLineID, anchor: .center)
        }
    }

    // MARK: - Ledger

    private var ledgerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ledgerHeader

            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(height: 1)

            ScrollView {
                LedgerContentView(tester: tester)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.035))
    }

    private var ledgerHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.clipboard")
                .font(.caption2.weight(.semibold))

            Text("RUNNING LEDGER")
                .font(.caption2.weight(.bold))
                .tracking(1.4)

            Spacer(minLength: 8)

            if tester.isResponding {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.65))
            }

            if !tester.ledgerCopyText.isEmpty {
                Button {
                    copyToClipboard(tester.ledgerCopyText)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy running ledger")
            }
        }
        .foregroundStyle(.white.opacity(0.5))
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            Color.black

            RadialGradient(
                colors: [
                    accentColor.opacity(0.32),
                    accentColor.opacity(0.08),
                    .clear,
                ],
                center: .top,
                startRadius: 10,
                endRadius: 640
            )
            .blur(radius: 55)

            LinearGradient(
                colors: [.clear, .black.opacity(0.65)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 1.1), value: accentColor)
    }
}

// MARK: - Line

private struct ConversationLineRow: View {
    let line: TimedTranscriptLine
    let isActive: Bool
    let showsSpeaker: Bool
    let isLive: Bool

    private var speakerColor: Color {
        ConversationPalette.color(for: line.speakerNumber)
    }

    var body: some View {
        VStack(spacing: 5) {
            if showsSpeaker, let number = line.speakerNumber {
                Text("SPEAKER \(number)")
                    .font(.caption2.weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(speakerColor.opacity(isActive ? 1 : 0.6))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(speakerColor.opacity(isActive ? 0.18 : 0.09), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(speakerColor.opacity(isActive ? 0.26 : 0.10), lineWidth: 1)
                    }
            }

            KaraokeLine(line: line, isActive: isActive, isLive: isLive)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .multilineTextAlignment(.leading)
                .lineSpacing(2)
                .shadow(color: .white.opacity(isActive ? 0.12 : 0), radius: 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .scaleEffect(isActive ? 1 : 0.94, anchor: .leading)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
        .opacity(isActive ? 1 : 0.4)
        .blur(radius: isActive ? 0 : 0.3)
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: isActive)
    }
}

/// Renders one conversation line and fills its words in while the recognizer
/// is still producing volatile text. Finalized lines are always fully lit.
private struct KaraokeLine: View {
    let line: TimedTranscriptLine
    let isActive: Bool
    let isLive: Bool

    @State private var startedAt = Date.now

    private var isAnimating: Bool {
        isLive && isActive && !line.isFinal
    }

    private var tokens: [String] {
        let words = line.text.split(whereSeparator: \.isWhitespace).map(String.init)
        return words.count > 1 ? words : line.text.map(String.init)
    }

    private var usesWordTokens: Bool {
        line.text.contains(where: \.isWhitespace)
    }

    /// Reveal pace. Word-based text fills about three words per second; text
    /// without spaces (for example Chinese or Japanese) fills by character.
    private var tokenInterval: TimeInterval {
        usesWordTokens ? 0.30 : 0.13
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !isAnimating)) { timeline in
            let reveal = revealState(at: timeline.date)
            highlightedText(filledCount: reveal.filled, currentFraction: reveal.fraction)
        }
        .onChange(of: isActive) { _, active in
            if active {
                startedAt = .now
            }
        }
    }

    private func revealState(at date: Date) -> (filled: Int, fraction: Double) {
        guard isAnimating else { return (tokens.count, 1) }

        let elapsed = max(0, date.timeIntervalSince(startedAt))
        let exact = elapsed / tokenInterval
        let filled = min(tokens.count, Int(exact))
        let fraction = filled < tokens.count ? exact - Double(filled) : 1
        return (filled, min(max(fraction, 0), 1))
    }

    private func highlightedText(filledCount: Int, currentFraction: Double) -> Text {
        guard !tokens.isEmpty else { return Text("") }

        var attributed = AttributedString()

        for (index, token) in tokens.enumerated() {
            let color: Color
            if index < filledCount {
                color = .white
            } else if index == filledCount {
                color = .white.opacity(0.30 + 0.45 * currentFraction)
            } else {
                color = .white.opacity(0.24)
            }

            var tokenString = AttributedString(token)
            tokenString.foregroundColor = color
            attributed += tokenString

            if usesWordTokens, index < tokens.count - 1 {
                var space = AttributedString(" ")
                space.foregroundColor = color
                attributed += space
            }
        }

        return Text(attributed)
    }
}

// MARK: - Palette

private enum ConversationPalette {
    static let speakerColors: [Color] = [.cyan, .pink, .mint, .orange]

    static func color(for speakerNumber: Int?) -> Color {
        guard let speakerNumber, speakerNumber > 0 else { return .blue }
        return speakerColors[(speakerNumber - 1) % speakerColors.count]
    }
}

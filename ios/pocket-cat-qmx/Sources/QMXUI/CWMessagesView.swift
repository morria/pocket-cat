// CW as a messaging thread: the radio's decoder fills the left side, the
// compose field keys the right side. Deliberately shaped like Messages —
// bubbles, day/time separators, a capsule compose bar with a circular
// send button — because that is the mental model for a CW ragchew.

import CATBridgeKit
import QMXKit
import SwiftUI

struct CWMessagesView: View {
    @Environment(RigController.self) private var rig
    @State private var messenger = CWMessenger()
    @State private var draft = ""
    @FocusState private var composeFocused: Bool
    @Bindable private var settings = AppSettings.shared
    /// Tokens a tapped template needed but the operator hasn't filled in.
    @State private var missingFields: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            macroStrip
            composeBar
        }
        .navigationTitle("CW")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) { ConnectionStatusButton() }
            ToolbarItem(placement: .primaryAction) { menu }
        }
        .task {
            messenger.session = rig.session
            messenger.startListening()
        }
        .onDisappear { messenger.stopListening() }
        .onChange(of: rig.connectionPhase) {
            messenger.session = rig.session
        }
        .alert("Unsupported characters",
               isPresented: .init(get: { messenger.notice != nil },
                                  set: { if !$0 { messenger.notice = nil } })) {
            Button("OK", role: .cancel) { messenger.notice = nil }
        } message: {
            Text(messenger.notice ?? "")
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if messenger.messages.isEmpty { emptyState }
                    ForEach(Array(messenger.messages.enumerated()),
                            id: \.element.id) { index, message in
                        if let stamp = separator(before: index) {
                            Text(stamp)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                        }
                        CWBubble(message: message) {
                            Task { await messenger.retry(message.id) }
                        }
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            // Tapping the transcript also dismisses — the same way Messages
            // behaves, and a second escape route if the Done button is
            // missed.
            .contentShape(Rectangle())
            .onTapGesture { composeFocused = false }
            .onChange(of: messenger.messages.last?.id) { _, id in
                guard let id else { return }
                withAnimation(.snappy) { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No CW yet")
                .font(.headline)
            Text(rig.session == nil
                 ? "Connect to a bridge, or pick the simulated QMX."
                 : "Decoded CW appears here. Type below to send.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 80)
        .padding(.horizontal, 32)
    }

    /// A Messages-style stamp above the first bubble and whenever the
    /// conversation has been quiet for a while.
    private func separator(before index: Int) -> String? {
        let message = messenger.messages[index]
        guard index > 0 else { return Self.stamp.string(from: message.date) }
        let previous = messenger.messages[index - 1].date
        guard message.date.timeIntervalSince(previous) > 300 else { return nil }
        return Self.stamp.string(from: message.date)
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - Compose

    /// Chips fill the field; they never send by themselves. Callsigns
    /// spotted in the copy come first, so a reply is one tap.
    private var macroStrip: some View {
        VStack(spacing: 4) {
            if !missingFields.isEmpty {
                Label("Set \(StationIdentity.describe(missingFields)) in "
                      + "Settings to use that template.",
                      systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(heardCallsigns, id: \.self) { call in
                        Button {
                            replyTo(call)
                        } label: {
                            Label(call, systemImage:
                                    "antenna.radiowaves.left.and.right")
                        }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                    }
                    ForEach(visibleTemplates) { template in
                        Button(template.label) { apply(template) }
                            .font(.footnote.weight(.medium))
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                            .tint(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Templates needing a station to address are hidden until one is heard.
    private var visibleTemplates: [CWTemplate] {
        CWTemplate.defaults.filter {
            !$0.needsTheirCall || !heardCallsigns.isEmpty
        }
    }

    private var heardCallsigns: [String] {
        CallsignSpotter.recentCallsigns(
            in: messenger.messages.filter { $0.direction == .received }
                .map(\.text),
            excluding: settings.callsign)
    }

    private func apply(_ template: CWTemplate) {
        let expanded = settings.station.expand(template.text,
                                               theirCall: heardCallsigns.first)
        guard expanded.missing.isEmpty else {
            missingFields = expanded.missing
            return
        }
        missingFields = []
        draft = expanded.text
        composeFocused = true
    }

    private func replyTo(_ call: String) {
        let expanded = settings.station.expand(
            "{THEIRCALL} DE {CALL} {CALL} K", theirCall: call)
        missingFields = expanded.missing
        guard expanded.missing.isEmpty else { return }
        draft = expanded.text
        composeFocused = true
    }

    private var composeBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // In-layout escape from the keyboard. The keyboard covers the
            // tab bar, so without this the screen is a dead end — and a
            // keyboard-toolbar button alone proved too easy to miss.
            if composeFocused {
                Button {
                    composeFocused = false
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel("Hide keyboard")
                .transition(.opacity)
            }

            TextField(fieldPrompt, text: $draft, axis: .vertical)
                .font(.callout.monospaced())
                .lineLimit(1...4)
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                #endif
                .autocorrectionDisabled()
                .focused($composeFocused)
                #if os(iOS)
                // Attached to the field itself: keyboard toolbars are more
                // reliable here than on an ancestor container.
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { composeFocused = false }
                    }
                }
                #endif
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .overlay(
                    Capsule().strokeBorder(Color.separatorTint, lineWidth: 1)
                )
                .onSubmit(send)

            Button(action: send) {
                // An empty field turns Send into "repeat last" — the
                // workhorse of calling CQ (Dits does the same).
                Image(systemName: canRepeat ? "repeat.circle.fill"
                                            : "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white,
                                     (canSend || canRepeat)
                                        ? Color.accentColor
                                        : Color.secondary.opacity(0.4))
            }
            .disabled(!canSend && !canRepeat)
            .accessibilityLabel(canRepeat ? "Repeat last message" : "Send as CW")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .animation(.snappy(duration: 0.15), value: composeFocused)
        .safeAreaInset(edge: .top, spacing: 0) { onAirEstimate }
    }

    /// How long the radio will be keyed. `KY` is buffered and reports no
    /// completion, so an estimate is the only warning before a long send.
    @ViewBuilder
    private var onAirEstimate: some View {
        let seconds = CWTiming.seconds(draft, wpm: rig.keyerSpeed ?? 20)
        if seconds > 0 {
            Text("≈ \(Int(seconds.rounded()))s on air at "
                 + "\(rig.keyerSpeed ?? 20) WPM")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 14)
                .padding(.bottom, 2)
        }
    }

    private var fieldPrompt: String {
        "Message · \(rig.keyerSpeed ?? 20) WPM"
    }

    private var canRepeat: Bool {
        !canSend && lastSentText != nil
    }

    private var lastSentText: String? {
        messenger.messages.last { $0.direction == .sent }?.text
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let outgoing = canSend ? draft : (lastSentText ?? "")
        guard !outgoing.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }
        if canSend { draft = "" }
        missingFields = []
        Task { await messenger.send(outgoing) }
    }

    // MARK: - Toolbar

    private var menu: some View {
        Menu {
            Picker("Keyer speed", selection: keyerBinding) {
                ForEach([12, 15, 18, 20, 22, 25, 28, 30], id: \.self) { wpm in
                    Text("\(wpm) WPM").tag(wpm)
                }
            }
            Divider()
            Button("Clear transcript", systemImage: "trash",
                   role: .destructive) {
                messenger.clear()
            }
        } label: {
            Label("Options", systemImage: "ellipsis.circle")
        }
    }

    private var keyerBinding: Binding<Int> {
        .init(get: { rig.keyerSpeed ?? 20 },
              set: { wpm in Task { await rig.setKeyerSpeed(wpm) } })
    }
}

// MARK: - Bubble

private struct CWBubble: View {
    let message: CWMessage
    let retry: () -> Void

    private var isSent: Bool { message.direction == .sent }

    var body: some View {
        VStack(alignment: isSent ? .trailing : .leading, spacing: 2) {
            Text(message.text)
                .font(.body)
                .foregroundStyle(isSent ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: 18,
                                            style: .continuous))
                .opacity(isPending ? 0.55 : 1)
                .textSelection(.enabled)

            switch message.state {
            case .failed(let reason):
                Button(action: retry) {
                    Label("Not sent — \(reason). Tap to retry.",
                          systemImage: "exclamationmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            case .sending:
                Text("Sending…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .keyed:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: isSent ? .trailing : .leading)
        .padding(isSent ? .leading : .trailing, 56)
        .padding(.vertical, 1)
    }

    private var isPending: Bool {
        if case .sending = message.state { return true }
        return false
    }

    private var background: Color {
        isSent ? .accentColor : .secondaryFill
    }
}

// MARK: - Platform colours

extension Color {
    /// The grey Messages uses for incoming bubbles.
    static var secondaryFill: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemFill)
        #else
        Color.secondary.opacity(0.18)
        #endif
    }

    static var separatorTint: Color {
        #if os(iOS)
        Color(uiColor: .separator)
        #else
        Color.secondary.opacity(0.35)
        #endif
    }
}

#Preview {
    NavigationStack { CWMessagesView() }
        .environment(RigController())
}

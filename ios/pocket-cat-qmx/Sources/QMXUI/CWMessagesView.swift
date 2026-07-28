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

    private static let macros = ["CQ CQ DE", "RST 599", "73", "TU", "AGN?"]

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
            // The keyboard covers the tab bar, so without a way out of the
            // field there is no way off this screen.
            #if os(iOS)
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { composeFocused = false }
            }
            #endif
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

    private var macroStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Self.macros, id: \.self) { macro in
                    Button {
                        draft = draft.isEmpty ? macro : draft + " " + macro
                        composeFocused = true
                    } label: {
                        Text(macro)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.secondaryFill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
    }

    private var composeBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("CW message", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                #endif
                .autocorrectionDisabled()
                .focused($composeFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .overlay(
                    Capsule().strokeBorder(Color.separatorTint, lineWidth: 1)
                )
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, canSend ? Color.accentColor
                                                     : Color.secondary.opacity(0.4))
            }
            .disabled(!canSend)
            .accessibilityLabel("Send as CW")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        let outgoing = draft
        draft = ""
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

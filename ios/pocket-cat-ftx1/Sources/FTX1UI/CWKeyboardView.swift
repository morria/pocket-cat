// CW by keyboard: type it, the radio's memory keyer sends it (`KY`).
//
// Send-only, and the screen says so. The QMX app pairs this with a live
// transcript because that radio decodes CW in hardware and hands the text
// over on `TB`; a Yaesu has no such command, so there is nothing honest to
// show on the receive side.

import CATBridgeKit
import FTX1Kit
import SwiftUI

struct CWKeyboardView: View {
    @Environment(RigController.self) private var rig
    @Bindable private var settings = AppSettings.shared
    @State private var draft = ""
    @State private var sent: [SentMessage] = []
    @State private var notice: String?
    @FocusState private var composeFocused: Bool

    private struct SentMessage: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let date: Date
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            templateStrip
            composeBar
        }
        .navigationTitle("CW")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) { ConnectionStatusButton() }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Keyer speed", selection: keyerBinding) {
                        ForEach([12, 15, 18, 20, 22, 25, 28, 30], id: \.self) {
                            Text("\($0) WPM").tag($0)
                        }
                    }
                    Divider()
                    Button("Clear", systemImage: "trash", role: .destructive) {
                        sent.removeAll()
                    }
                } label: {
                    Label("Options", systemImage: "ellipsis.circle")
                }
            }
        }
        .alert("Unsupported characters", isPresented: .init(
            get: { notice != nil },
            set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    // MARK: - Sent list

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .trailing, spacing: 6) {
                    if sent.isEmpty { emptyState }
                    ForEach(sent) { message in
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(message.text)
                                .font(.body)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(Color.accentColor,
                                            in: RoundedRectangle(
                                                cornerRadius: 18,
                                                style: .continuous))
                            Text(estimate(for: message.text))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: sent.last?.id) { _, id in
                guard let id else { return }
                withAnimation(.snappy) { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Send CW by keyboard", systemImage: "keyboard")
        } description: {
            Text("Typed text goes to the radio's memory keyer, which sends "
                 + "it at the current speed. There is no decoder — a Yaesu "
                 + "doesn't hand decoded CW back over CAT.")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: - Compose

    private var templateStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(CWTemplate.defaults) { template in
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

    private var composeBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if composeFocused {
                Button { composeFocused = false } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel("Hide keyboard")
            }

            TextField("Message · \(rig.keyerSpeed ?? 20) WPM",
                      text: $draft, axis: .vertical)
                .font(.callout.monospaced())
                .lineLimit(1...4)
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                #endif
                .autocorrectionDisabled()
                .focused($composeFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))

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
        .safeAreaInset(edge: .top, spacing: 0) { draftEstimate }
    }

    @ViewBuilder
    private var draftEstimate: some View {
        let seconds = CWTiming.seconds(draft, wpm: rig.keyerSpeed ?? 20)
        if seconds > 0 {
            Text("≈ \(Int(seconds.rounded()))s on air")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 14)
        }
    }

    private var canSend: Bool {
        rig.session != nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func estimate(for text: String) -> String {
        let seconds = CWTiming.seconds(text, wpm: rig.keyerSpeed ?? 20)
        return "≈ \(Int(seconds.rounded()))s at \(rig.keyerSpeed ?? 20) WPM"
    }

    private func apply(_ template: CWTemplate) {
        let expanded = settings.station.expand(template.text)
        guard expanded.missing.isEmpty else {
            notice = "Set \(StationIdentity.describe(expanded.missing)) in "
                + "Settings to use that template."
            return
        }
        draft = expanded.text
        composeFocused = true
    }

    private func send() {
        let (text, dropped) = CWText.normalize(draft)
        if !dropped.isEmpty {
            notice = "Morse can't carry "
                + dropped.sorted().map(String.init).joined(separator: " ")
                + " — removed."
        }
        guard !text.isEmpty else { return }
        draft = ""
        sent.append(SentMessage(text: text, date: Date()))
        Task { await rig.sendKeyerText(text) }
    }

    private var keyerBinding: Binding<Int> {
        .init(get: { rig.keyerSpeed ?? 20 },
              set: { wpm in Task { await rig.setKeyerSpeed(wpm) } })
    }
}

#Preview {
    NavigationStack { CWKeyboardView() }.environment(RigController())
}

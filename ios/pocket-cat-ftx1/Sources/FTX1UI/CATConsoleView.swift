// A raw CAT console.
//
// Several FTX-1 command formats aren't documented in this repo — the
// passband's `SH`/`IS`, `KY` keying, Super DX — and guessing at them writes
// the wrong thing to a real transmitter. This makes probing them a
// ten-second loop instead of a rebuild: type a command, read the reply,
// and the ones that work get wired into the app.

import CATBridgeKit
import FTX1Kit
import SwiftUI

struct CATConsoleView: View {
    @Environment(RigController.self) private var rig
    @State private var command = ""
    @State private var log: [Exchange] = []
    @State private var busy = false

    private struct Exchange: Identifiable {
        let id = UUID()
        let sent: String
        let reply: String
        let rejected: Bool
    }

    /// Commands worth trying first for the things that don't work yet.
    private static let suggestions = [
        "SH0;", "SH01;", "NA0;", "IS0;", "PA0;", "SQ0;", "PC;", "EX0101;",
    ]

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(log.reversed()) { exchange in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(exchange.sent)
                                .font(.callout.monospaced())
                            Text(exchange.reply)
                                .font(.callout.monospaced())
                                .foregroundStyle(exchange.rejected
                                                 ? .orange : .secondary)
                        }
                    }
                    if log.isEmpty {
                        Text("Replies appear here. `?;` means the radio "
                             + "rejected the command — usually the wrong "
                             + "field width.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Exchanges")
                }
            }

            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(Self.suggestions, id: \.self) { suggestion in
                        Button(suggestion) { command = suggestion }
                            .font(.footnote.monospaced())
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)

            HStack(spacing: 8) {
                TextField("FA;", text: $command)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, canSend ? Color.accentColor
                                                         : Color.secondary.opacity(0.4))
                }
                .disabled(!canSend)
                if busy { ProgressView() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle("CAT Console")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear", role: .destructive) { log.removeAll() }
                    .disabled(log.isEmpty)
            }
        }
    }

    private var canSend: Bool {
        rig.session != nil && command.hasSuffix(";") && !busy
    }

    private func send() {
        guard canSend else { return }
        let wire = command
        busy = true
        Task {
            defer { busy = false }
            do {
                // Reads and writes both go through here; a command with no
                // reply simply logs "(no reply)".
                let reply = try await rig.rawCAT(wire)
                log.append(Exchange(sent: wire,
                                    reply: reply ?? "(no reply)",
                                    rejected: reply == "?;"))
            } catch {
                log.append(Exchange(sent: wire,
                                    reply: "error: \(error)",
                                    rejected: true))
            }
        }
    }
}

#Preview {
    NavigationStack { CATConsoleView() }.environment(RigController())
}

// The centerpiece frequency readout: monospaced digits, per-digit vertical
// drag tuning (each digit tunes its own decade), tap for direct entry.

import CATBridgeKit
import FT891Kit
import SwiftUI

struct FrequencyDisplay: View {
    @Environment(RigController.self) private var rig
    @State private var showingKeypad = false

    var body: some View {
        let hz = rig.state?.frequency?.hertz ?? 0
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                ForEach(digitSlots(for: hz)) { slot in
                    switch slot.kind {
                    case .separator:
                        Text(".")
                            .font(digitFont)
                            .foregroundStyle(.secondary)
                    case let .digit(char, decade, dim):
                        TunableDigit(char: char, decade: decade, dim: dim)
                    }
                }
                Text("MHz")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
            }
            .contentShape(Rectangle())
            .onTapGesture { showingKeypad = true }
            .accessibilityElement()
            .accessibilityLabel("Frequency")
            .accessibilityValue(Frequency(hz: hz).description)
            .accessibilityAdjustableAction { direction in
                rig.step(by: direction == .increment ? 1000 : -1000)
            }
        }
        .sensoryFeedback(.selection, trigger: hz)
        .sheet(isPresented: $showingKeypad) {
            FrequencyEntrySheet()
                .presentationDetents([.height(220)])
        }
    }

    private var digitFont: Font {
        .system(size: 44, weight: .light, design: .rounded)
        .monospacedDigit()
    }

    private struct Slot: Identifiable {
        enum Kind {
            case digit(Character, decade: Int64, dim: Bool)
            case separator
        }

        let id: Int
        let kind: Kind
    }

    /// 9-digit layout `MM.kkk.hhh` with leading zeros dimmed.
    private func digitSlots(for hz: UInt64) -> [Slot] {
        let text = String(format: "%09d", hz)
        var slots: [Slot] = []
        var significant = false
        for (index, char) in text.enumerated() {
            if index == 3 || index == 6 {
                slots.append(Slot(id: 100 + index, kind: .separator))
            }
            if char != "0" { significant = true }
            let decade = Int64(pow(10.0, Double(8 - index)))
            // Dim leading zeros down to the 1 MHz place.
            let dim = !significant && index < 2
            slots.append(Slot(id: index,
                              kind: .digit(char, decade: decade, dim: dim)))
        }
        return slots
    }
}

/// One digit; vertical drag tunes its decade with a detent every 14 pt.
private struct TunableDigit: View {
    @Environment(RigController.self) private var rig
    let char: Character
    let decade: Int64
    let dim: Bool

    @State private var lastSteps = 0

    var body: some View {
        Text(String(char))
            .font(.system(size: 44, weight: .light, design: .rounded)
                .monospacedDigit())
            .foregroundStyle(dim ? .tertiary : .primary)
            .frame(minWidth: 26)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        let steps = -Int(value.translation.height / 14)
                        let delta = steps - lastSteps
                        if delta != 0 {
                            rig.step(by: Int64(delta) * decade)
                            lastSteps = steps
                        }
                    }
                    .onEnded { _ in lastSteps = 0 }
            )
            .accessibilityHidden(true)
    }
}

/// Direct frequency entry ("14.074" → 14.074 MHz).
private struct FrequencyEntrySheet: View {
    @Environment(RigController.self) private var rig
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Enter Frequency")
                .font(.headline)
            TextField("14.074", text: $text)
                .font(.system(size: 34, design: .rounded).monospacedDigit())
                .multilineTextAlignment(.center)
                .focused($focused)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .onSubmit(commit)
            Button("Tune", action: commit)
                .buttonStyle(.borderedProminent)
                .disabled(parsedHz == nil)
        }
        .padding()
        .onAppear { focused = true }
    }

    private var parsedHz: UInt64? {
        guard let mhz = Double(text.replacingOccurrences(of: ",", with: ".")),
              mhz > 0.03, mhz <= 56 else { return nil }
        return UInt64((mhz * 1_000_000).rounded())
    }

    private func commit() {
        guard let hz = parsedHz else { return }
        rig.tune(to: Frequency(hz: hz))
        dismiss()
    }
}

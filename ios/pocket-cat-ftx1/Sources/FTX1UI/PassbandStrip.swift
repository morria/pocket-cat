// The passband strip (docs/passband.md §4), reworked after UX review:
// visible affordances (edge grab handles, knobbed notch marker), labeled
// toggle chips for notch/contour, an overflow menu for resets, a live
// value bubble while dragging, and 1:1 horizontal drag mapping —
// predictable over clever, per the HIG. Tap-to-notch remains the fast
// path; the chips make the same state reachable by labeled control.

import CATBridgeKit
import FTX1Kit
import SwiftUI

struct PassbandStrip: View {
    @Environment(RigController.self) private var rig
    let passband: PassbandController

    @State private var drag: DragState?
    @State private var snapTick = 0
    @State private var notchTick = false
    @State private var bubble: Bubble?

    private struct DragState {
        var target: PassbandGeometry.HitTarget
        var isContour = false
        var startShiftHz: Int
        var startWidthIndex: Int
        var startNotchHz: Int
        var startContourHz: Int
        var startX: CGFloat
    }

    private struct Bubble: Equatable {
        var text: String
        var x: CGFloat
    }

    var body: some View {
        content
            .task(id: taskKey) {
                passband.refresh(session: rig.session,
                                 mode: rig.state?.mode)
            }
    }

    /// Re-runs the refresh when connection or mode changes.
    private var taskKey: String {
        "\(String(describing: rig.state?.mode))-"
            + "\(rig.session == nil ? 0 : 1)"
    }

    @ViewBuilder
    private var content: some View {
        if let state = passband.state, passband.supportsPassband {
            strip(state: state)
        } else if passband.state != nil {
            summaryRow
        } else {
            // Never EmptyView: `.task` doesn't fire on a view that renders
            // nothing, and the refresh above is what loads the state.
            Color.clear.frame(height: 1)
        }
    }

    private var summaryRow: some View {
        HStack {
            Label("Passband", systemImage: "waveform.and.mic")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Not available in this mode")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
    }

    private func strip(state: PassbandState) -> some View {
        VStack(spacing: 6) {
            header(state: state)
            GeometryReader { geo in
                let geometry = PassbandGeometry(width: geo.size.width)
                canvas(state: state, geometry: geometry)
                    .gesture(stripGesture(state: state, geometry: geometry))
                    .gesture(tapGesture(state: state, geometry: geometry))
                    .overlay(alignment: .topLeading) {
                        bubbleView(width: geo.size.width)
                    }
            }
            .frame(height: 84)
            chipsRow(state: state)
            Text("Drag the band to shift · handles to resize · "
                 + "tap to notch a tone")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
        .sensoryFeedback(.selection, trigger: snapTick)
        .sensoryFeedback(.impact(weight: .light), trigger: notchTick)
        .accessibilityElement(children: .contain)
        .accessibilityRepresentation { accessibilityStand(state: state) }
    }

    // MARK: - Header: title, live values, overflow menu (resets live here)

    private func header(state: PassbandState) -> some View {
        HStack(spacing: 8) {
            Label("Passband", systemImage: "waveform.and.mic")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let widthHz = state.widthHz {
                Text(widthHz >= 1000
                     ? String(format: "%.1f kHz", Double(widthHz) / 1000)
                     : "\(widthHz) Hz")
                    .font(.caption.monospacedDigit())
            }
            if let shift = state.shiftHz, shift != 0 {
                Text("shift \(shift > 0 ? "+" : "")\(shift)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Center Shift",
                       systemImage: "arrow.uturn.backward") {
                    passband.centerShift()
                }
                .disabled((state.shiftHz ?? 0) == 0)
                Button(state.notchEnabled == true
                       ? "Notch Off" : "Notch On",
                       systemImage: "waveform.badge.minus") {
                    passband.setNotchEnabled(!(state.notchEnabled ?? false))
                }
                Button(state.contourEnabled == true
                       ? "Contour Off" : "Contour On",
                       systemImage: "point.topleft.down.curvedto.point.bottomright.up") {
                    passband.setContourEnabled(
                        !(state.contourEnabled ?? false))
                }
                Divider()
                Button("Reset All", systemImage: "arrow.counterclockwise",
                       role: .destructive) {
                    passband.resetAll()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Passband options")
        }
    }

    // MARK: - Toggle chips: labeled on/off, the discoverable path

    private func chipsRow(state: PassbandState) -> some View {
        HStack(spacing: 8) {
            chip("Notch", isOn: state.notchEnabled ?? false,
                 tint: .red) {
                passband.setNotchEnabled(!(state.notchEnabled ?? false))
                notchTick.toggle()
            }
            chip("Contour", isOn: state.contourEnabled ?? false,
                 tint: .orange) {
                passband.setContourEnabled(!(state.contourEnabled ?? false))
            }
            Spacer()
            if state.notchEnabled == true, let notch = state.notchHz {
                Text("notch \(notch) Hz")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.red)
            }
            if state.contourEnabled == true,
               let contour = state.contourHz {
                Text("contour \(contour) Hz")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.orange)
            }
        }
    }

    private func chip(_ title: String, isOn: Bool, tint: Color,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(isOn ? .semibold : .regular))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(isOn ? tint : .secondary)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: - Drawing

    private func canvas(state: PassbandState,
                        geometry: PassbandGeometry) -> some View {
        Canvas { context, size in
            let axisY = size.height - 12
            context.stroke(
                Path { $0.move(to: CGPoint(x: 0, y: axisY))
                       $0.addLine(to: CGPoint(x: size.width, y: axisY)) },
                with: .color(.secondary.opacity(0.4)), lineWidth: 1)
            for hz in stride(from: 0, through: 3400, by: 500) {
                let x = geometry.x(forHz: hz)
                context.stroke(
                    Path { $0.move(to: CGPoint(x: x, y: axisY))
                           $0.addLine(to: CGPoint(x: x, y: axisY + 5)) },
                    with: .color(.secondary.opacity(0.4)), lineWidth: 1)
            }

            if let widthHz = state.widthHz {
                let edges = geometry.passbandEdges(
                    widthHz: widthHz, shiftHz: state.shiftHz ?? 0)
                let lowX = geometry.x(forHz: edges.lowHz)
                let highX = geometry.x(forHz: edges.highHz)
                let rect = CGRect(x: lowX, y: 14, width: highX - lowX,
                                  height: axisY - 22)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 8),
                    with: .color(.accentColor.opacity(0.3)))
                context.stroke(
                    Path(roundedRect: rect, cornerRadius: 8),
                    with: .color(.accentColor), lineWidth: 1.5)

                // Visible grab handles: the affordance the edges lacked.
                for x in [lowX, highX] {
                    let handle = CGRect(x: x - 2.5, y: rect.midY - 11,
                                        width: 5, height: 22)
                    context.fill(
                        Path(roundedRect: handle, cornerRadius: 2.5),
                        with: .color(.accentColor))
                }
            }

            // Notch: line + knob so it reads as draggable. Hidden when
            // off — the chip is its presence indicator.
            if state.notchEnabled == true, let notchHz = state.notchHz {
                let x = geometry.x(forHz: notchHz)
                context.stroke(
                    Path { $0.move(to: CGPoint(x: x, y: 16))
                           $0.addLine(to: CGPoint(x: x, y: axisY)) },
                    with: .color(.red), lineWidth: 2)
                context.fill(
                    Path(ellipseIn: CGRect(x: x - 5, y: 8, width: 10,
                                           height: 10)),
                    with: .color(.red))
            }

            if state.contourEnabled == true, let contourHz = state.contourHz {
                let x = geometry.x(forHz: contourHz)
                let dome = CGRect(x: x - 10, y: axisY - 10, width: 20,
                                  height: 10)
                context.fill(Path(ellipseIn: dome), with: .color(.orange))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary.opacity(0.4)))
    }

    private func bubbleView(width: CGFloat) -> some View {
        Group {
            if let bubble {
                Text(bubble.text)
                    .font(.caption.monospacedDigit().weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .offset(x: min(max(bubble.x - 40, 0), width - 80),
                            y: -26)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: bubble)
        .allowsHitTesting(false)
    }

    // MARK: - Gestures

    private func stripGesture(state: PassbandState,
                              geometry: PassbandGeometry) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if drag == nil {
                    let target = geometry.hitTarget(
                        x: value.startLocation.x,
                        widthHz: state.widthHz ?? 0,
                        shiftHz: state.shiftHz ?? 0,
                        notchHz: state.notchHz,
                        notchEnabled: state.notchEnabled ?? false)
                    let isContour = state.contourEnabled == true
                        && value.startLocation.y > 58
                        && state.contourHz.map {
                            abs(value.startLocation.x - geometry.x(forHz: $0))
                                <= PassbandGeometry.edgeHitZone
                        } ?? false
                    drag = DragState(
                        target: target,
                        isContour: isContour,
                        startShiftHz: state.shiftHz ?? 0,
                        startWidthIndex: state.widthIndex ?? 0,
                        startNotchHz: state.notchHz ?? 0,
                        startContourHz: state.contourHz ?? 0,
                        startX: value.startLocation.x)
                    guard isContour || target != .empty else { return }
                    passband.beginDrag()
                }
                apply(value, state: state, geometry: geometry)
            }
            .onEnded { _ in
                if passband.isDragging {
                    passband.endDrag()
                }
                drag = nil
                bubble = nil
            }
    }

    private func apply(_ value: DragGesture.Value, state: PassbandState,
                       geometry: PassbandGeometry) {
        guard let drag else { return }
        // 1:1 horizontal mapping — predictable beats clever in a scroll
        // view (the old vertical-sensitivity trick fought scrolling).
        let deltaHz = Int(CGFloat(PassbandGeometry.axisMaxHz)
            * (value.location.x - drag.startX) / geometry.width)

        if drag.isContour {
            let hz = drag.startContourHz + deltaHz
            passband.setContour(hz: hz)
            bubble = Bubble(text: "Contour \(passband.state?.contourHz ?? hz) Hz",
                            x: value.location.x)
            return
        }
        switch drag.target {
        case .body:
            let before = passband.state?.shiftHz
            passband.setShift(hz: drag.startShiftHz + deltaHz)
            let now = passband.state?.shiftHz ?? 0
            if before != now { snapTick += 1 }
            bubble = Bubble(
                text: "Shift \(now > 0 ? "+" : "")\(now) Hz",
                x: value.location.x)
        case .leftEdge, .rightEdge:
            guard let family = passband.widthFamily else { return }
            let sign = drag.target == .leftEdge ? -1 : 1
            let startHz = family.widthHz(at: drag.startWidthIndex)
                ?? family.widths[family.indices.upperBound - 1]
            let index = family.index(
                forWidthHz: max(1, startHz + 2 * sign * deltaHz))
            if index != state.widthIndex { snapTick += 1 }
            passband.setWidth(index: index)
            if let hz = passband.state?.widthHz {
                bubble = Bubble(text: hz >= 1000
                    ? String(format: "Width %.1f kHz", Double(hz) / 1000)
                    : "Width \(hz) Hz",
                    x: value.location.x)
            }
        case .notch:
            passband.setNotch(hz: drag.startNotchHz + deltaHz)
            bubble = Bubble(
                text: "Notch \(passband.state?.notchHz ?? 0) Hz",
                x: value.location.x)
        case .empty:
            break
        }
    }

    private func tapGesture(state: PassbandState,
                            geometry: PassbandGeometry) -> some Gesture {
        SpatialTapGesture(count: 1)
            .onEnded { value in
                let target = geometry.hitTarget(
                    x: value.location.x,
                    widthHz: state.widthHz ?? 0,
                    shiftHz: state.shiftHz ?? 0,
                    notchHz: state.notchHz,
                    notchEnabled: state.notchEnabled ?? false)
                // Tap = place the notch (the one-gesture carrier fix).
                // Clearing moved to the chip/menu: a labeled, reversible
                // control instead of a hidden tap target.
                switch target {
                case .empty, .body:
                    passband.placeNotch(
                        hz: geometry.hz(forX: value.location.x))
                    notchTick.toggle()
                    bubble = Bubble(
                        text: "Notch \(passband.state?.notchHz ?? 0) Hz",
                        x: value.location.x)
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        bubble = nil
                    }
                case .notch, .leftEdge, .rightEdge:
                    break
                }
            }
    }

    // MARK: - Accessibility (§5)

    private func accessibilityStand(state: PassbandState) -> some View {
        VStack {
            if let shift = state.shiftHz {
                Stepper("IF shift, \(shift) hertz",
                        value: Binding(
                            get: { shift },
                            set: { passband.setShift(hz: $0) }),
                        step: PassbandTables.shiftStepHz)
            }
            if let index = state.widthIndex, let widthHz = state.widthHz {
                Stepper("Filter width, \(widthHz) hertz",
                        value: Binding(
                            get: { index },
                            set: { passband.setWidth(index: $0) }),
                        step: 1)
            }
            if let notch = state.notchHz {
                Stepper("Notch, \(notch) hertz, "
                        + (state.notchEnabled == true ? "on" : "off"),
                        value: Binding(
                            get: { notch },
                            set: { passband.setNotch(hz: $0) }),
                        step: PassbandTables.notchStepHz)
                Toggle("Notch enabled", isOn: Binding(
                    get: { state.notchEnabled ?? false },
                    set: { passband.setNotchEnabled($0) }))
            }
            if let contour = state.contourHz {
                Stepper("Contour, \(contour) hertz, "
                        + (state.contourEnabled == true ? "on" : "off"),
                        value: Binding(
                            get: { contour },
                            set: { passband.setContour(hz: $0) }),
                        step: 10)
                Toggle("Contour enabled", isOn: Binding(
                    get: { state.contourEnabled ?? false },
                    set: { passband.setContourEnabled($0) }))
            }
            Button("Center shift") { passband.centerShift() }
            Button("Reset passband") { passband.resetAll() }
        }
    }
}

/// One-tap auto notch, prominent beside the meter (§4.4): a steady
/// carrier should need no aiming.
struct AutoNotchButton: View {
    let passband: PassbandController

    var body: some View {
        let on = passband.state?.autoNotchEnabled ?? false
        Button {
            passband.setAutoNotch(!on)
        } label: {
            Label("DNF", systemImage: on
                  ? "waveform.badge.minus" : "waveform")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(on ? .red : nil)
        .accessibilityLabel("Auto notch filter")
        .accessibilityValue(on ? "on" : "off")
        .accessibilityHint("Removes steady carrier tones automatically")
    }
}

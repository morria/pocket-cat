// The passband strip (docs/passband.md §4): one spatial control for
// shift, width, notch and contour. Drawing is one Canvas over a fixed
// 0–3400 Hz axis; gestures resolve through PassbandGeometry; writes
// coalesce through PassbandController. Every parameter is also a
// VoiceOver adjustable element (§5).

import CATBridgeKit
import FT891Kit
import SwiftUI

struct PassbandStrip: View {
    @Environment(RigController.self) private var rig
    let passband: PassbandController

    @State private var drag: DragState?
    @State private var hapticTick = 0

    private struct DragState {
        var target: PassbandGeometry.HitTarget
        var isContour = false
        var startShiftHz: Int
        var startWidthIndex: Int
        var startNotchHz: Int
        var startContourHz: Int
        var startX: CGFloat
    }

    var body: some View {
        content
            .task(id: taskKey) {
                passband.refresh(session: rig.session,
                                 mode: rig.state?.mode)
            }
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

    /// Re-runs the refresh when connection or mode changes.
    private var taskKey: String {
        "\(String(describing: rig.state?.mode))-"
            + "\(rig.session == nil ? 0 : 1)"
    }

    /// AM/FM: nothing to control beyond auto-notch — one line, no strip.
    private var summaryRow: some View {
        Text("Passband controls are unavailable in this mode.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
    }

    private func strip(state: PassbandState) -> some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let geometry = PassbandGeometry(width: geo.size.width)
                canvas(state: state, geometry: geometry)
                    .gesture(stripGesture(state: state, geometry: geometry))
                    .gesture(tapGesture(state: state, geometry: geometry))
            }
            .frame(height: 80)
            legend(state: state)
        }
        .padding(.horizontal)
        .sensoryFeedback(.selection, trigger: hapticTick)
        .accessibilityElement(children: .contain)
        .accessibilityRepresentation { accessibilityStand(state: state) }
    }

    // MARK: - Drawing (§4.1)

    private func canvas(state: PassbandState,
                        geometry: PassbandGeometry) -> some View {
        Canvas { context, size in
            // Axis + ticks every 500 Hz.
            let axisY = size.height - 12
            context.stroke(
                Path { $0.move(to: CGPoint(x: 0, y: axisY))
                       $0.addLine(to: CGPoint(x: size.width, y: axisY)) },
                with: .color(.secondary.opacity(0.5)), lineWidth: 1)
            for hz in stride(from: 0, through: 3400, by: 500) {
                let x = geometry.x(forHz: hz)
                context.stroke(
                    Path { $0.move(to: CGPoint(x: x, y: axisY))
                           $0.addLine(to: CGPoint(x: x, y: axisY + 5)) },
                    with: .color(.secondary.opacity(0.5)), lineWidth: 1)
            }

            // Passband capsule.
            if let widthHz = state.widthHz {
                let edges = geometry.passbandEdges(
                    widthHz: widthHz, shiftHz: state.shiftHz ?? 0)
                let lowX = geometry.x(forHz: edges.lowHz)
                let highX = geometry.x(forHz: edges.highHz)
                let rect = CGRect(x: lowX, y: 12, width: highX - lowX,
                                  height: axisY - 20)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 8),
                    with: .color(.accentColor.opacity(0.35)))
                context.stroke(
                    Path(roundedRect: rect, cornerRadius: 8),
                    with: .color(.accentColor), lineWidth: 1.5)
            }

            // Notch marker: a vertical line, dimmed when disabled.
            if let notchHz = state.notchHz {
                let x = geometry.x(forHz: notchHz)
                let enabled = state.notchEnabled ?? false
                context.stroke(
                    Path { $0.move(to: CGPoint(x: x, y: 6))
                           $0.addLine(to: CGPoint(x: x, y: axisY)) },
                    with: .color(.red.opacity(enabled ? 0.9 : 0.25)),
                    lineWidth: 2)
            }

            // Contour handle: low-profile dome on the axis.
            if let contourHz = state.contourHz {
                let x = geometry.x(forHz: contourHz)
                let enabled = state.contourEnabled ?? false
                let dome = CGRect(x: x - 9, y: axisY - 9, width: 18,
                                  height: 9)
                context.fill(
                    Path(ellipseIn: dome),
                    with: .color(.orange.opacity(enabled ? 0.9 : 0.3)))
            }
        }
    }

    private func legend(state: PassbandState) -> some View {
        HStack {
            if let widthHz = state.widthHz {
                Text("\(widthHz) Hz")
            }
            if let shift = state.shiftHz, shift != 0 {
                Text("shift \(shift > 0 ? "+" : "")\(shift)")
            }
            if state.notchEnabled == true, let notch = state.notchHz {
                Text("notch \(notch)").foregroundStyle(.red)
            }
            if state.contourEnabled == true, let contour = state.contourHz {
                Text("contour \(contour)").foregroundStyle(.orange)
            }
            Spacer()
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    // MARK: - Gestures (§4.2)

    private func stripGesture(state: PassbandState,
                              geometry: PassbandGeometry) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if drag == nil {
                    let target = geometry.hitTarget(
                        x: value.startLocation.x,
                        widthHz: state.widthHz ?? 0,
                        shiftHz: state.shiftHz ?? 0,
                        notchHz: state.notchHz,
                        notchEnabled: state.notchEnabled ?? false)
                    // Contour dome: bottom band around its position wins.
                    let isContour = state.contourEnabled == true
                        && value.startLocation.y > 55
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
            }
    }

    private func apply(_ value: DragGesture.Value, state: PassbandState,
                       geometry: PassbandGeometry) {
        guard let drag else { return }
        // Vertical distance scales sensitivity (§4.2).
        let sensitivity = PassbandGeometry.sensitivity(
            verticalDistance: value.location.y - 40)
        let deltaHz = Int(CGFloat(PassbandGeometry.axisMaxHz)
            * (value.location.x - drag.startX) / geometry.width
            * sensitivity)

        if drag.isContour {
            passband.setContour(hz: drag.startContourHz + deltaHz)
            return
        }
        switch drag.target {
        case .body:
            passband.setShift(hz: drag.startShiftHz + deltaHz)
        case .leftEdge, .rightEdge:
            guard let family = passband.widthFamily else { return }
            // Dragging an edge by ΔHz changes width by 2Δ (symmetric);
            // left edge inverts.
            let sign = drag.target == .leftEdge ? -1 : 1
            let startHz = family.widthHz(at: drag.startWidthIndex)
                ?? family.widths[family.indices.upperBound - 1]
            let index = family.index(
                forWidthHz: max(1, startHz + 2 * sign * deltaHz))
            if index != state.widthIndex {
                hapticTick += 1 // snap feedback per index change (§4.3)
            }
            passband.setWidth(index: index)
        case .notch:
            passband.setNotch(hz: drag.startNotchHz + deltaHz)
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
                switch target {
                case .notch:
                    // Tap an enabled notch marker: disable it (stands in
                    // for double-tap, which fights the drag recognizer).
                    passband.setNotchEnabled(false)
                case .empty:
                    passband.placeNotch(
                        hz: geometry.hz(forX: value.location.x))
                case .body, .leftEdge, .rightEdge:
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

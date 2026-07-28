// Pure geometry for the passband strip (docs/passband.md §4.1, §6):
// x ↔ Hz mapping, hit-testing, and the vertical-distance sensitivity
// curve. No UI types beyond CGFloat so it tests headless.

import CoreGraphics

public struct PassbandGeometry: Sendable, Equatable {
    /// Receive-audio axis, 0…3400 Hz (§4.1).
    public static let axisMaxHz = 3400
    /// Nominal audio centre the capsule shifts around.
    public static let centreHz = 1700
    /// Edge grab zones extend this far each side of the edge (§4.2).
    public static let edgeHitZone: CGFloat = 22

    public var width: CGFloat

    public init(width: CGFloat) {
        self.width = width
    }

    public func x(forHz hz: Int) -> CGFloat {
        width * CGFloat(hz) / CGFloat(Self.axisMaxHz)
    }

    public func hz(forX x: CGFloat) -> Int {
        let clamped = min(max(x, 0), width)
        return Int((clamped / width * CGFloat(Self.axisMaxHz)).rounded())
    }

    /// Capsule edges for a given width and shift (§4.1: centre ± width/2,
    /// offset by shift), clamped to the axis.
    public func passbandEdges(widthHz: Int, shiftHz: Int)
        -> (lowHz: Int, highHz: Int) {
        let low = Self.centreHz - widthHz / 2 + shiftHz
        let high = Self.centreHz + widthHz / 2 + shiftHz
        return (max(0, low), min(Self.axisMaxHz, high))
    }

    public enum HitTarget: Equatable, Sendable {
        case leftEdge
        case rightEdge
        case body
        case notch
        case empty
    }

    /// Hit-test a touch. Edge zones win over the body; the notch marker
    /// wins over everything when the touch is within its zone and the
    /// notch is enabled.
    public func hitTarget(x: CGFloat, widthHz: Int, shiftHz: Int,
                          notchHz: Int?, notchEnabled: Bool) -> HitTarget {
        if notchEnabled, let notchHz {
            let nx = self.x(forHz: notchHz)
            if abs(x - nx) <= Self.edgeHitZone {
                return .notch
            }
        }
        let edges = passbandEdges(widthHz: widthHz, shiftHz: shiftHz)
        let lowX = self.x(forHz: edges.lowHz)
        let highX = self.x(forHz: edges.highHz)
        if abs(x - lowX) <= Self.edgeHitZone
            && abs(x - lowX) <= abs(x - highX) {
            return .leftEdge
        }
        if abs(x - highX) <= Self.edgeHitZone {
            return .rightEdge
        }
        if x > lowX && x < highX {
            return .body
        }
        return .empty
    }

    /// Camera-style sensitivity: 1.0 at the strip, tapering to 0.1 at
    /// ≥100 pt vertical distance (§4.2).
    public static func sensitivity(verticalDistance: CGFloat) -> CGFloat {
        let d = min(max(abs(verticalDistance), 0), 100)
        return 1.0 - 0.9 * d / 100
    }
}

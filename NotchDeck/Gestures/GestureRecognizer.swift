import CoreGraphics
import Foundation

/// Turns two-finger scroll deltas over the collapsed notch into actions: one track skip per
/// horizontal gesture (with a short cooldown), or continuous volume steps vertically.
struct GestureRecognizer {
    enum Action: Equatable {
        case next, previous
        /// Volume change as a fraction (1/16 per step, like the volume keys).
        case volume(Float)
    }

    /// Points of travel needed for a skip.
    var threshold: CGFloat = 60
    var invert = false
    var swipeEnabled = true
    var verticalVolume = false

    private enum Axis { case horizontal, vertical }
    private var axis: Axis?
    private var accX: CGFloat = 0
    private var accY: CGFloat = 0
    private var fired = false
    private var lastEvent: TimeInterval = -1
    private var cooldownUntil: TimeInterval = 0

    /// `dx`/`dy` follow the fingers: +x = right, +y = up (already corrected for natural scrolling).
    mutating func feed(dx: CGFloat, dy: CGFloat, began: Bool, at time: TimeInterval) -> Action? {
        if began || time - lastEvent > 0.3 { axis = nil; accX = 0; accY = 0; fired = false }
        lastEvent = time
        accX += dx; accY += dy
        if axis == nil, max(abs(accX), abs(accY)) > 8 {
            axis = abs(accX) >= abs(accY) ? .horizontal : .vertical
        }
        switch axis {
        case .horizontal:
            guard swipeEnabled, !fired, time >= cooldownUntil, abs(accX) > threshold else { return nil }
            fired = true
            cooldownUntil = time + 0.4
            return (accX > 0) != invert ? .next : .previous
        case .vertical:
            let unit = threshold / 3
            guard verticalVolume, abs(accY) >= unit else { return nil }
            let steps = (accY / unit).rounded(.towardZero)
            accY -= steps * unit
            return .volume(Float(steps) / 16)
        case nil:
            return nil
        }
    }
}

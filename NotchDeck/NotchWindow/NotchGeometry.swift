import AppKit

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    var hasNotch: Bool { safeAreaInsets.top > 0 }

    /// Physical notch size, or a simulated pill on displays without one.
    var notchSize: CGSize {
        if hasNotch, let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea {
            return CGSize(width: frame.width - left.width - right.width, height: safeAreaInsets.top)
        }
        return CGSize(width: 180, height: 30)
    }

    /// The menu bar is hidden (full-screen app or auto-hide): visible frame reaches the top edge.
    var menuBarHidden: Bool { visibleFrame.maxY >= frame.maxY - 0.5 }

    /// Rect of `size` flush with the top centre of this screen, in screen coordinates.
    func topCentered(_ size: CGSize) -> CGRect {
        CGRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height)
    }
}

import Foundation
import CoreGraphics
import ApplicationServices

/// Maps normalised tablet pointer events onto a display's global coordinate space and posts
/// CGEvents. Only active when the user opted in AND macOS Accessibility permission is granted.
/// This is pointer emulation (click / drag / right-click / scroll), not native multitouch.
public final class InputInjector {
    public init() {}

    public static func isTrusted(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    private var leftDown = false
    private var rightDown = false
    private var lastDownTime: TimeInterval = 0
    private var lastDownPoint = CGPoint.zero
    private var clickCount: Int64 = 1
    private let source = CGEventSource(stateID: .hidSystemState)

    /// Pure mapping, exposed for unit tests. `bounds` is in global points (top-left origin).
    public static func map(_ e: PointerEvent, into bounds: CGRect) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        // Keep the point strictly inside the display so it never lands on a neighbour.
        let x = bounds.minX + min(max(e.normalizedX, 0), 1) * (bounds.width - 1)
        let y = bounds.minY + min(max(e.normalizedY, 0), 1) * (bounds.height - 1)
        return CGPoint(x: x.rounded(.down), y: y.rounded(.down))
    }

    public func handle(_ e: PointerEvent, displayBounds: CGRect) {
        guard displayBounds.width > 0 else { return }
        let p = Self.map(e, into: displayBounds)
        switch e.action {
        case .move:
            let type: CGEventType = leftDown ? .leftMouseDragged : (rightDown ? .rightMouseDragged : .mouseMoved)
            post(type, p, leftDown ? .left : (rightDown ? .right : .left))
        case .down:
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastDownTime < NSEventDoubleClickInterval() && hypot(p.x - lastDownPoint.x, p.y - lastDownPoint.y) < 12 {
                clickCount = min(clickCount + 1, 3)
            } else { clickCount = 1 }
            lastDownTime = now; lastDownPoint = p
            // Move first so hover state / focus follow the click target.
            post(.mouseMoved, p, .left)
            if e.button == .left { leftDown = true; post(.leftMouseDown, p, .left) }
            else { rightDown = true; post(.rightMouseDown, p, .right) }
        case .up:
            if e.button == .left { if leftDown { leftDown = false; post(.leftMouseUp, p, .left) } }
            else { if rightDown { rightDown = false; post(.rightMouseUp, p, .right) } }
        case .scroll:
            post(.mouseMoved, p, .left)
            if let ev = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                wheel1: Int32(e.scrollY), wheel2: Int32(e.scrollX), wheel3: 0) {
                ev.post(tap: .cghidEventTap)
            }
        case .cancel:
            releaseAll(at: p)
        }
    }

    public func releaseAll(at p: CGPoint? = nil) {
        let point = p ?? CGEvent(source: nil)?.location ?? .zero
        if leftDown { leftDown = false; post(.leftMouseUp, point, .left) }
        if rightDown { rightDown = false; post(.rightMouseUp, point, .right) }
    }

    private func post(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton) {
        guard let ev = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        if type == .leftMouseDown || type == .leftMouseUp || type == .rightMouseDown || type == .rightMouseUp {
            ev.setIntegerValueField(.mouseEventClickState, value: clickCount)
        }
        ev.post(tap: .cghidEventTap)
    }
}

private func NSEventDoubleClickInterval() -> TimeInterval {
    // NSEvent.doubleClickInterval without importing AppKit into the core module.
    let v = UserDefaults.standard.double(forKey: "com.apple.mouse.doubleClickThreshold")
    return v > 0 ? v : 0.5
}

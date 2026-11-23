import Foundation
import CoreGraphics
import EPVirtualDisplayBridge

public enum Arrangement: String, CaseIterable, Codable {
    /// Let macOS remember whatever the user set in System Settings → Displays.
    case automatic, right, left, above, below
}

public enum VirtualDisplayError: Error, CustomStringConvertible {
    case unsupported(String)
    case creationFailed(String)
    case settingsRejected
    public var description: String {
        switch self {
        case .unsupported(let r): return "Virtual displays are not supported on this macOS: \(r)"
        case .creationFailed(let r): return "Could not create the virtual display: \(r)"
        case .settingsRejected: return "macOS rejected the virtual display modes"
        }
    }
}

/// Owns the single "ExtendPad Display". Must be used on the main thread.
///
/// Safety: the display belongs to this process's WindowServer connection, so if ExtendPad quits
/// or crashes, macOS removes it and moves its windows back to the remaining displays. Nothing
/// can be orphaned across a crash or reboot.
public final class VirtualDisplayManager {
    public static let displayName = "ExtendPad Display"
    // Stable identity → macOS remembers arrangement/scaling for this display across sessions.
    static let vendorID: UInt32 = 0x4550      // "EP"
    static let productID: UInt32 = 0x0D01
    static let serial: UInt32 = 0x4550_0001

    public private(set) var displayID: CGDirectDisplayID = 0
    public private(set) var plan: DisplayPlan?
    private var display: EPVirtualDisplay?
    public var onTerminated: (() -> Void)?

    public init() {}

    public static var isSupported: Bool { EPVirtualDisplay.isSupported() }
    public static var unsupportedReason: String { EPVirtualDisplay.unsupportedReason() }

    public var isActive: Bool { display != nil && displayID != 0 }

    /// Creates the display (or reconfigures the existing one, keeping its windows) for `plan`.
    @discardableResult
    public func ensure(_ plan: DisplayPlan, arrangement: Arrangement) throws -> CGDirectDisplayID {
        dispatchPrecondition(condition: .onQueue(.main))
        if let display, let current = self.plan {
            if current.displayKey == plan.displayKey {
                self.plan = plan
                return displayID
            }
            if current.maxPixelsWide >= plan.maxPixelsWide && current.maxPixelsHigh >= plan.maxPixelsHigh {
                // Same display, new modes: windows stay put.
                if display.applyModes(Self.specs(plan), hiDPI: plan.hiDPI) {
                    self.plan = plan
                    selectMode(plan)
                    logInfo("display", "reconfigured \(Self.displayName) → \(plan.displayKey)")
                    return displayID
                }
            }
            destroy(reason: "resolution change needs a larger framebuffer")
        }

        guard EPVirtualDisplay.isSupported() else { throw VirtualDisplayError.unsupported(EPVirtualDisplay.unsupportedReason()) }
        let d: EPVirtualDisplay
        do {
          d = try EPVirtualDisplay(name: Self.displayName,
                                 maxPixelsWide: UInt32(plan.maxPixelsWide), maxPixelsHigh: UInt32(plan.maxPixelsHigh),
                                 sizeInMillimeters: plan.sizeInMillimeters,
                                 vendorID: Self.vendorID, productID: Self.productID, serialNumber: Self.serial,
                                 terminationHandler: { [weak self] in
                                     logWarn("display", "WindowServer terminated the virtual display")
                                     self?.display = nil
                                     self?.displayID = 0
                                     self?.plan = nil
                                     self?.onTerminated?()
                                 })
        } catch {
            throw VirtualDisplayError.creationFailed(error.localizedDescription)
        }
        guard d.applyModes(Self.specs(plan), hiDPI: plan.hiDPI) else {
            d.invalidate()
            throw VirtualDisplayError.settingsRejected
        }
        display = d
        displayID = d.displayID
        self.plan = plan
        // Don't block the main thread: select the mode as soon as WindowServer reports it online.
        whenOnline(displayID) { [weak self] in
            guard let self, self.displayID == d.displayID, let current = self.plan else { return }
            self.selectMode(current)
            self.applyArrangement(arrangement)
        }
        logInfo("display", "created \(Self.displayName) id=\(displayID) logical=\(plan.logicalWidth)x\(plan.logicalHeight) pixels=\(plan.pixelWidth)x\(plan.pixelHeight) hiDPI=\(plan.hiDPI)")
        return displayID
    }

    public func destroy(reason: String) {
        guard let display else { return }
        logInfo("display", "removing \(Self.displayName) (\(reason))")
        display.invalidate()
        self.display = nil
        displayID = 0
        plan = nil
    }

    private static func specs(_ plan: DisplayPlan) -> [EPVirtualDisplayModeSpec] {
        plan.modes.map { EPVirtualDisplayModeSpec(width: UInt32($0.width), height: UInt32($0.height), refreshRate: 60) }
    }

    private func whenOnline(_ id: CGDirectDisplayID, attempt: Int = 0, _ body: @escaping () -> Void) {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var n: UInt32 = 0
        CGGetOnlineDisplayList(32, &ids, &n)
        if ids.prefix(Int(n)).contains(id) { body(); return }
        guard attempt < 100 else { logWarn("display", "display \(id) not reported online after 5 s"); body(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.whenOnline(id, attempt: attempt + 1, body) }
    }

    /// macOS picks an arbitrary default mode for new virtual displays, so select ours explicitly
    /// with the public CGDisplay mode API.
    public func selectMode(_ plan: DisplayPlan) {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode] else { return }
        let match = modes.first {
            $0.width == plan.logicalWidth && $0.height == plan.logicalHeight &&
            $0.pixelWidth == plan.pixelWidth && $0.pixelHeight == plan.pixelHeight
        } ?? modes.first { $0.width == plan.logicalWidth && $0.height == plan.logicalHeight }
        guard let mode = match else {
            logWarn("display", "no mode \(plan.logicalWidth)x\(plan.logicalHeight) (px \(plan.pixelWidth)x\(plan.pixelHeight)) offered; keeping default")
            return
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
        let err = CGCompleteDisplayConfiguration(config, .forSession)
        if err != .success { logWarn("display", "set mode failed: \(err.rawValue)") }
    }

    /// Places the display relative to the main display (unless `.automatic`).
    public func applyArrangement(_ arrangement: Arrangement) {
        guard isActive, arrangement != .automatic else { return }
        let main = CGDisplayBounds(CGMainDisplayID())
        let me = CGDisplayBounds(displayID)
        var origin = CGPoint.zero
        switch arrangement {
        case .right: origin = CGPoint(x: main.maxX, y: main.minY + (main.height - me.height) / 2)
        case .left: origin = CGPoint(x: main.minX - me.width, y: main.minY + (main.height - me.height) / 2)
        case .above: origin = CGPoint(x: main.minX + (main.width - me.width) / 2, y: main.minY - me.height)
        case .below: origin = CGPoint(x: main.minX + (main.width - me.width) / 2, y: main.maxY)
        case .automatic: return
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        CGConfigureDisplayOrigin(config, displayID, Int32(origin.x.rounded()), Int32(origin.y.rounded()))
        let err = CGCompleteDisplayConfiguration(config, .permanently)
        if err != .success { logWarn("display", "arrangement failed: \(err.rawValue)") }
    }

    /// Global (top-left origin, points) bounds of the virtual display, for input mapping.
    public var bounds: CGRect { isActive ? CGDisplayBounds(displayID) : .zero }
}

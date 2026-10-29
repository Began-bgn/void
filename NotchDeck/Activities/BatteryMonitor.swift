import Foundation
import IOKit.ps
import SwiftUI

struct BatteryReading: Equatable {
    var percent: Int
    var onAC: Bool
    var charging: Bool
    var charged: Bool
}

enum BatteryEvent: Equatable {
    case pluggedIn(charging: Bool), unplugged, chargingStarted, fullyCharged, low(threshold: Int)

    /// Pure transition logic: which pop-ups a change in power state should raise.
    static func events(from old: BatteryReading?, to new: BatteryReading, thresholds: [Int]) -> [BatteryEvent] {
        guard let old else { return [] }
        var out: [BatteryEvent] = []
        if new.onAC, !old.onAC {
            out.append(.pluggedIn(charging: new.charging))
        } else if !new.onAC, old.onAC {
            out.append(.unplugged)
        } else if new.onAC, new.charging, !old.charging {
            out.append(.chargingStarted)
        }
        if new.onAC, new.charged, !old.charged { out.append(.fullyCharged) }
        // Lowest threshold crossed while on battery.
        if !new.onAC, let t = thresholds.sorted().first(where: { old.percent > $0 && new.percent <= $0 }) {
            out.append(.low(threshold: t))
        }
        return out
    }
}

/// macOS Low Power Mode. While on, the notch drops its continuous animations to save battery.
@MainActor @Observable
final class LowPowerMode {
    static let shared = LowPowerMode()
    private(set) var isOn = ProcessInfo.processInfo.isLowPowerModeEnabled
    @ObservationIgnored private var token: NSObjectProtocol?

    private init() {
        token = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LowPowerMode.shared.isOn = ProcessInfo.processInfo.isLowPowerModeEnabled }
        }
    }
}

/// IOKit power-source notifications (no polling). Always running: the notch header shows the live
/// level; the pop-ups follow the Battery setting.
@MainActor @Observable
final class BatteryMonitor {
    static let shared = BatteryMonitor()
    private(set) var reading: BatteryReading?
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private let settings = SettingsStore.shared

    private init() {}

    func start() {
        guard source == nil else { return }
        reading = Self.read()
        guard reading != nil else { return } // no internal battery (desktop Mac)
        source = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { BatteryMonitor.shared.update() }
        }, nil)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
    }

    /// IOKit sends bursts with transient states (unplugging briefly reports "charging"), so wait for
    /// the power state to settle and compare only the settled reading with the last one.
    private func update() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.settle()
        }
    }

    private func settle() {
        guard let new = Self.read() else { return }
        let thresholds = [settings.lowBatteryThreshold1, settings.lowBatteryThreshold2]
        for event in BatteryEvent.events(from: reading, to: new, thresholds: thresholds) where settings.activityBattery {
            if let flash = flash(for: event, reading: new) { ActivityCenter.shared.show(flash) }
        }
        reading = new
    }

    static func read() -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let percent = current * 100 / max
            return BatteryReading(
                percent: percent,
                onAC: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                charged: d[kIOPSIsChargedKey] as? Bool ?? (percent >= 100))
        }
        return nil
    }

    /// iPhone: yellow while Low Power Mode is on, green otherwise.
    static var chargeColor: Color { ProcessInfo.processInfo.isLowPowerModeEnabled ? .yellow : .clockGreen }

    /// Plugging in always shows "Plugged In"; charging starting later shows nothing.
    private func flash(for event: BatteryEvent, reading r: BatteryReading) -> ActivityFlash? {
        switch event {
        case .pluggedIn:
            .battery(percent: r.percent, title: String(localized: "Plugged In"), color: Self.chargeColor, glyph: "powerplug.fill")
        case .chargingStarted:
            nil
        case .unplugged:
            .battery(percent: r.percent, title: String(localized: "Not Charging"), color: .white, glyph: nil)
        case .fullyCharged:
            .battery(percent: r.percent, title: String(localized: "Fully Charged"), color: Self.chargeColor, glyph: "powerplug.fill")
        case .low:
            .battery(percent: r.percent, title: String(localized: "Low Battery"), color: .red, glyph: nil)
        }
    }
}

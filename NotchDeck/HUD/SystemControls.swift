import AppKit
import CoreAudio
import AudioToolbox

/// Default output device volume and mute through CoreAudio.
enum SystemVolume {
    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static var device: AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    private static func settable(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Bool {
        var addr = address(selector)
        var ok: DarwinBoolean = false
        return AudioObjectHasProperty(id, &addr) && AudioObjectIsPropertySettable(id, &addr, &ok) == noErr && ok.boolValue
    }

    /// Nil when the device has no software volume (e.g. some HDMI outputs): leave those to macOS.
    static var volume: Float? {
        get {
            guard let id = device, settable(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume) else { return nil }
            var v = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? v : nil
        }
        set {
            guard let id = device, var v = newValue.map({ Float32($0.clamped(to: 0...1)) }) else { return }
            var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
    }

    static var isMuted: Bool {
        get {
            guard let id = device else { return false }
            var m = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            var addr = address(kAudioDevicePropertyMute)
            return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &m) == noErr && m != 0
        }
        set {
            guard let id = device, settable(id, kAudioDevicePropertyMute) else { return }
            var m = UInt32(newValue ? 1 : 0)
            var addr = address(kAudioDevicePropertyMute)
            AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        }
    }
}

/// Display brightness, kept behind a protocol: the only implementation uses a private framework.
protocol BrightnessControl {
    /// Nil when this display can't be controlled; the key then goes to macOS (native HUD).
    func brightness(of display: CGDirectDisplayID) -> Float?
    func setBrightness(_ value: Float, of display: CGDirectDisplayID)
}

/// DisplayServices (private): built-in panels and Apple external displays. Other externals report
/// no brightness and fall back to the native behaviour.
struct DisplayServicesBrightness: BrightnessControl {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private let get: Get?
    private let set: Set?

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        get = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: Get.self) }
        set = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: Set.self) }
    }

    func brightness(of display: CGDirectDisplayID) -> Float? {
        guard let get, set != nil else { return nil }
        var v: Float = 0
        return get(display, &v) == 0 ? v : nil
    }

    func setBrightness(_ value: Float, of display: CGDirectDisplayID) {
        _ = set?(display, value.clamped(to: 0...1))
    }
}

/// Keyboard backlight through CoreBrightness' `KeyboardBrightnessClient` (private). Nil = unsupported.
@MainActor
final class KeyboardBacklight {
    static let shared = KeyboardBacklight()
    private let client: NSObject?
    private let keyboard: UInt64
    private var beforeToggle: Float = 0.5

    private init() {
        Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework")?.load()
        client = (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type)?.init()
        let ids = client?.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber]
        keyboard = ids?.first?.uint64Value ?? 1
    }

    var level: Float? {
        let sel = NSSelectorFromString("brightnessForKeyboard:")
        guard let client, client.responds(to: sel) else { return nil }
        typealias F = @convention(c) (AnyObject, Selector, UInt64) -> Float
        return unsafeBitCast(client.method(for: sel), to: F.self)(client, sel, keyboard)
    }

    func set(_ value: Float) {
        let sel = NSSelectorFromString("setBrightness:forKeyboard:")
        guard let client, client.responds(to: sel) else { return }
        typealias F = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
        _ = unsafeBitCast(client.method(for: sel), to: F.self)(client, sel, value.clamped(to: 0...1), keyboard)
    }

    /// Backlight on/off key: remembers the level to restore.
    func toggle() -> Float? {
        guard let current = level else { return nil }
        if current > 0 { beforeToggle = current; set(0); return 0 }
        set(beforeToggle); return beforeToggle
    }
}

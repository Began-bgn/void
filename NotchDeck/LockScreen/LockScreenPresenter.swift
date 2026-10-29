import AppKit
import OSLog

/// Puts windows above the lock screen. Every implementation must fail closed: when anything goes
/// wrong it reports `isSupported == false` and leaves no window on screen.
@MainActor
protocol LockScreenPresenter: AnyObject {
    var isSupported: Bool { get }
    /// Last failure, for Settings → Lock Screen → Diagnostics.
    var lastError: String? { get }
    func show(_ windows: [NSWindow])
    func hide()
}

/// Feature off or unsupported: shows nothing.
@MainActor
final class NullLockScreenPresenter: LockScreenPresenter {
    let isSupported = false
    let lastError: String?
    init(reason: String? = nil) { lastError = reason }
    func show(_ windows: [NSWindow]) {}
    func hide() {}
}

/// Private SkyLight (window server) space API, resolved at runtime. No hard link: a missing
/// symbol makes `load` return nil and the feature turns itself off.
///
/// Signatures follow public reverse-engineering write-ups of the `CGS`/`SLS` space calls (the
/// same ones window managers use). Symbol presence is checked with `dlsym`; behaviour by the spike.
struct SkyLightAPI {
    typealias SpaceID = UInt64
    typealias MainConnectionID = @convention(c) () -> Int32
    typealias SpaceCreate = @convention(c) (Int32, Int, UnsafeRawPointer?) -> SpaceID
    typealias SpaceDestroy = @convention(c) (Int32, SpaceID) -> Int32
    typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, SpaceID, Int32) -> Int32
    typealias ShowHideSpaces = @convention(c) (Int32, CFArray) -> Void
    typealias SpaceAddWindows = @convention(c) (Int32, SpaceID, CFArray, Int32) -> Void

    static let symbolNames = [
        "SLSMainConnectionID", "SLSSpaceCreate", "SLSSpaceDestroy", "SLSSpaceSetAbsoluteLevel",
        "SLSShowSpaces", "SLSHideSpaces", "SLSSpaceAddWindowsAndRemoveFromSpaces",
    ]

    let mainConnectionID: MainConnectionID
    let spaceCreate: SpaceCreate
    let spaceDestroy: SpaceDestroy
    let setAbsoluteLevel: SpaceSetAbsoluteLevel
    let showSpaces: ShowHideSpaces
    let hideSpaces: ShowHideSpaces
    let addWindows: SpaceAddWindows

    /// Symbols that did not resolve, or nil when every one did.
    static func missingSymbols(resolve: (String) -> UnsafeMutableRawPointer? = dlsymSkyLight) -> [String] {
        symbolNames.filter { resolve($0) == nil }
    }

    /// `resolve` is injectable so tests can simulate missing symbols.
    static func load(resolve: (String) -> UnsafeMutableRawPointer? = dlsymSkyLight) -> SkyLightAPI? {
        var found: [String: UnsafeMutableRawPointer] = [:]
        for name in symbolNames {
            guard let p = resolve(name) else { return nil }
            found[name] = p
        }
        func fn<T>(_ name: String, _: T.Type) -> T { unsafeBitCast(found[name]!, to: T.self) }
        return SkyLightAPI(
            mainConnectionID: fn("SLSMainConnectionID", MainConnectionID.self),
            spaceCreate: fn("SLSSpaceCreate", SpaceCreate.self),
            spaceDestroy: fn("SLSSpaceDestroy", SpaceDestroy.self),
            setAbsoluteLevel: fn("SLSSpaceSetAbsoluteLevel", SpaceSetAbsoluteLevel.self),
            showSpaces: fn("SLSShowSpaces", ShowHideSpaces.self),
            hideSpaces: fn("SLSHideSpaces", ShowHideSpaces.self),
            addWindows: fn("SLSSpaceAddWindowsAndRemoveFromSpaces", SpaceAddWindows.self))
    }

    static func dlsymSkyLight(_ name: String) -> UnsafeMutableRawPointer? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        return dlsym(handle, name)
    }
}

/// Creates one window-server space at the lock screen's level and moves the given windows into
/// it. The first failing call disables the presenter for the rest of the session.
@MainActor
final class SkyLightLockScreenPresenter: LockScreenPresenter {
    /// Absolute space level of Notification Center while the screen is locked (public write-ups).
    static let lockScreenLevel: Int32 = 400

    private let api: SkyLightAPI
    private let log = Logger(subsystem: "com.notchdeck.app", category: "LockScreen")
    private var space: SkyLightAPI.SpaceID?
    private var windows: [NSWindow] = []
    private(set) var isSupported = true
    private(set) var lastError: String?

    init?(api: SkyLightAPI? = .load()) {
        guard let api else { return nil }
        self.api = api
    }

    func show(_ windows: [NSWindow]) {
        guard isSupported else { return }
        let cid = api.mainConnectionID()
        if space == nil {
            let sid = api.spaceCreate(cid, 1, nil)
            log.notice("space created \(sid) cid \(cid)")
            guard sid != 0 else { return fail("SLSSpaceCreate returned 0") }
            space = sid
            guard check(api.setAbsoluteLevel(cid, sid, Self.lockScreenLevel), "SLSSpaceSetAbsoluteLevel") else { return }
            api.showSpaces(cid, [NSNumber(value: sid)] as CFArray)
        }
        guard let sid = space else { return }
        for w in self.windows where !windows.contains(w) { w.orderOut(nil) }
        self.windows = windows
        for w in windows { w.orderFrontRegardless() }
        let ids = windows.map { NSNumber(value: $0.windowNumber) } as CFArray
        log.notice("adding windows \(windows.map(\.windowNumber), privacy: .public) frames \(windows.map { NSStringFromRect($0.frame) }, privacy: .public)")
        api.addWindows(cid, sid, ids, 7)
    }

    /// Always safe to call: tears down whatever exists.
    func hide() {
        for w in windows { w.orderOut(nil) }
        windows = []
        guard let sid = space else { return }
        space = nil
        let cid = api.mainConnectionID()
        api.hideSpaces(cid, [NSNumber(value: sid)] as CFArray)
        _ = api.spaceDestroy(cid, sid)
    }

    private func check(_ status: Int32, _ call: String) -> Bool {
        if status == 0 { return true }
        fail("\(call) failed (\(status))")
        return false
    }

    private func fail(_ message: String) {
        log.error("Lock screen player disabled: \(message, privacy: .public)")
        lastError = message
        isSupported = false
        hide()
    }
}

import AppKit
import AVFoundation
import Carbon.HIToolbox
import OSLog
import Security

/// Face Unlock step 1: answers the four "does this work on the lock screen?" questions before any
/// feature code exists. Run `NotchDeck --face-unlock-spike`, lock, hover the notch, unlock, then
/// read `~/Library/Logs/NotchDeck/face-unlock-spike.txt`.
///
/// Never touches the user's password: the keychain probe stores a dummy value and the entry probe
/// types "abc" then deletes it, without Return, so no unlock attempt is ever made.
@MainActor
final class FaceUnlockSpike {
    static let shared = FaceUnlockSpike()
    static var isRequested: Bool { CommandLine.arguments.contains("--face-unlock-spike") }

    private let log = Logger(subsystem: "com.notchdeck.app", category: "FaceUnlockSpike")
    private let monitor = LockStateMonitor()
    private var presenter: (any LockScreenPresenter)?
    private var window: NSPanel?
    private var hoverView: HoverProbeView?
    private var run: Task<Void, Never>?
    private var lines: [String] = []

    private static let keychainValue = Data("notchdeck-spike-dummy".utf8)
    private static let dpService = "com.notchdeck.faceunlock.spike.dp"
    private static let accessGroup = "F63KU4246G.com.notchdeck.app.faceunlock"
    private static let fileService = "com.notchdeck.faceunlock.spike.file"

    private init() {}

    func start() {
        presenter = SkyLightLockScreenPresenter()
        // Prompts happen now, while unlocked: camera TCC and Accessibility (needed to post keys).
        AVCaptureDevice.requestAccess(for: .video) { _ in }
        if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
        var setup = ["setup \(Date())", "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        setup.append("keychain write (data protection, AfterFirstUnlockThisDeviceOnly): \(Self.describe(Self.store(service: Self.dpService, dataProtection: true)))")
        setup.append("keychain write (file-based login keychain): \(Self.describe(Self.store(service: Self.fileService, dataProtection: false)))")
        setup.append("SkyLight presenter: \(presenter == nil ? "unavailable, missing \(SkyLightAPI.missingSymbols())" : "loaded")")
        Self.write(setup)
        monitor.onChange = { [weak self] old, new in
            if new.onLockScreen, !old.onLockScreen { self?.locked() }
            if !new.onLockScreen, old.onLockScreen { self?.unlocked() }
        }
        monitor.start()
        log.notice("spike armed")
    }

    func teardown() {
        run?.cancel(); run = nil
        presenter?.hide()
        window = nil
        hoverView = nil
    }

    // MARK: Lock cycle

    private func locked() {
        lines = ["lock \(Date())"]
        run = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled else { return }
            self.showHoverWindow()
            self.lines.append("keychain read (data protection): \(Self.describe(Self.read(service: Self.dpService, dataProtection: true)))")
            self.lines.append("keychain read (file-based): \(Self.describe(Self.read(service: Self.fileService, dataProtection: false)))")
            self.lines.append("camera: \(await CameraProbe().run(seconds: 5))")
            guard !Task.isCancelled else { return }
            await self.entryProbe()
        }
    }

    private func unlocked() {
        lines.append(contentsOf: hoverView?.summary ?? ["hover: no window was shown"])
        lines.append("unlock \(Date())")
        teardown()
        Self.write(lines)
        log.notice("spike report written")
    }

    // MARK: Probes

    private func showHoverWindow() {
        guard let presenter, presenter.isSupported, let screen = NSScreen.screens.first else {
            lines.append("hover: presenter unsupported (\(presenter?.lastError ?? "no SkyLight"))")
            return
        }
        let n = screen.notchSize
        let frame = screen.topCentered(CGSize(width: n.width + 80, height: n.height + 30))
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.canBecomeVisibleWithoutLogin = true
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        let view = HoverProbeView(notchRect: frame)
        panel.contentView = view
        window = panel
        hoverView = view
        presenter.show([panel])
        if let error = presenter.lastError { lines.append("hover: presenter failed: \(error)") }
    }

    /// Types "abc" into whatever has keyboard focus on the lock screen, then deletes it. The user
    /// watches the password field for three dots. Each post re-checks the lock so nothing reaches
    /// a normal app if the user unlocked meanwhile.
    private func entryProbe() async {
        lines.append("secure event input enabled: \(IsSecureEventInputEnabled())")
        lines.append("post-event (Accessibility) access: \(CGPreflightPostEventAccess())")
        guard CGPreflightPostEventAccess() else { lines.append("entry: skipped, no Accessibility access"); return }
        let a = CGKeyCode(kVK_ANSI_A), b = CGKeyCode(kVK_ANSI_B), c = CGKeyCode(kVK_ANSI_C)
        guard Self.post([a, b, c]) else { lines.append("entry: aborted, screen no longer locked"); return }
        lines.append("entry: posted 'abc' at \(Date()) (expect 3 dots in the password field)")
        try? await Task.sleep(for: .seconds(3))
        let delete = CGKeyCode(kVK_Delete)
        lines.append(Self.post([delete, delete, delete]) ? "entry: posted 3 deletes" : "entry: deletes skipped, unlocked")
    }

    private static func post(_ keys: [CGKeyCode]) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        for key in keys {
            guard LockStateMonitor.screenIsLocked else { return false }
            CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
        }
        return true
    }

    // MARK: Keychain

    private static func query(_ service: String, dataProtection: Bool) -> [CFString: Any] {
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "spike"]
        if dataProtection {
            q[kSecUseDataProtectionKeychain] = true
            q[kSecAttrAccessGroup] = accessGroup
        }
        return q
    }

    private static func store(service: String, dataProtection: Bool) -> OSStatus {
        let q = query(service, dataProtection: dataProtection)
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData] = keychainValue
        add[kSecAttrSynchronizable] = false
        if dataProtection { add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
        return SecItemAdd(add as CFDictionary, nil)
    }

    private static func read(service: String, dataProtection: Bool) -> OSStatus {
        var q = query(service, dataProtection: dataProtection)
        q[kSecReturnData] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecSuccess, (out as? Data) != keychainValue { return errSecDecode }
        return status
    }

    private static func describe(_ status: OSStatus) -> String {
        status == errSecSuccess ? "ok" : "\(status) \(SecCopyErrorMessageString(status, nil) as String? ?? "")"
    }

    // MARK: Report

    static let reportURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/NotchDeck/face-unlock-spike.txt")

    private static func write(_ lines: [String]) {
        let text = lines.joined(separator: "\n") + "\n\n"
        try? FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: reportURL) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: reportURL)
        }
    }
}

/// Counts tracking-area events on the lock-screen window, and separately polls the global cursor
/// position, so the report shows which hover signal (if any) survives the lock screen.
private final class HoverProbeView: NSView {
    private let notchRect: CGRect
    private var entered = 0, moved = 0, clicks = 0
    private var polledInside = 0, polledPositions = Set<String>()
    private var timer: Timer?

    init(notchRect: CGRect) {
        self.notchRect = notchRect
        super.init(frame: CGRect(origin: .zero, size: notchRect.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.6).cgColor
        layer?.cornerRadius = 10
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { entered += 1 }
    override func mouseMoved(with event: NSEvent) { moved += 1 }
    override func mouseDown(with event: NSEvent) { clicks += 1 }

    private func poll() {
        let p = NSEvent.mouseLocation
        polledPositions.insert("\(Int(p.x)),\(Int(p.y))")
        if notchRect.contains(p) { polledInside += 1 }
    }

    /// Also stops polling; called once on unlock.
    var summary: [String] {
        timer?.invalidate()
        return [
            "hover tracking area: entered \(entered), moved \(moved), clicks \(clicks)",
            "hover polling NSEvent.mouseLocation: \(polledPositions.count) distinct positions, \(polledInside) samples inside notch area",
        ]
    }
}

/// Runs the built-in camera at 640x480 for a fixed time and reports frames and errors.
private final class CameraProbe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.notchdeck.spike.camera")
    private let session = AVCaptureSession()
    private var frames = 0 // touched only on `queue`
    private var events: [String] = [] // touched only on `queue`

    func run(seconds: Double) async -> String {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            return "not authorized (status \(AVCaptureDevice.authorizationStatus(for: .video).rawValue))"
        }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices
        guard let device = devices.first, let input = try? AVCaptureDeviceInput(device: device) else { return "no built-in camera" }
        let tokens = [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] note in
                let detail = "\(name.rawValue) \(note.userInfo ?? [:])"
                self?.queue.async { self?.events.append(detail) }
            }
        }
        defer { tokens.forEach(NotificationCenter.default.removeObserver) }
        return await withCheckedContinuation { done in
            queue.async { [self] in
                session.beginConfiguration()
                session.sessionPreset = .vga640x480
                let output = AVCaptureVideoDataOutput()
                output.setSampleBufferDelegate(self, queue: queue)
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    session.commitConfiguration()
                    return done.resume(returning: "cannot configure session")
                }
                session.addInput(input)
                session.addOutput(output)
                session.commitConfiguration()
                session.startRunning()
                let running = session.isRunning
                queue.asyncAfter(deadline: .now() + seconds) { [self] in
                    session.stopRunning()
                    done.resume(returning: "\(device.localizedName): running=\(running), \(frames) frames in \(seconds) s, events \(events)")
                }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frames += 1
    }
}

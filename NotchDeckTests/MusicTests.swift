import AppKit
import Testing
@testable import NotchDeck

@Suite struct TimeFormatTests {
    @Test func formats() {
        #expect(formatTime(0) == "0:00")
        #expect(formatTime(5.9) == "0:05")
        #expect(formatTime(65) == "1:05")
        #expect(formatTime(3599) == "59:59")
        #expect(formatTime(4503) == "75:03")
    }

    @Test func clampsBadInput() {
        #expect(formatTime(-3) == "0:00")
        #expect(formatTime(.nan) == "0:00")
        #expect(formatTime(.infinity) == "0:00")
    }
}

@Suite struct MusicParserTests {
    private let d = String(MusicSnapshot.separator)
    private func join(_ f: [String]) -> String { f.joined(separator: d) }

    @Test func parsesSpotify() throws {
        let raw = join(["playing", "Song", "Artist", "Album", "215000", "12,5", "https://i.scdn.co/x", "70",
                        "spotify:track:1", "true", "false"])
        let s = try #require(MusicSnapshot.parse(raw, source: .spotify))
        #expect(s.state == .playing)
        #expect(s.duration == 215)
        #expect(s.position == 12.5)
        #expect(s.volume == 70)
        #expect(s.shuffle && !s.repeating)
        #expect(s.isFavorite == nil)
        #expect(s.artworkURL?.host == "i.scdn.co")
    }

    @Test func parsesAppleMusic() throws {
        let raw = join(["paused", "T", "A", "B", "180.5", "30.25", "", "40", "99", "false", "all", "true"])
        let s = try #require(MusicSnapshot.parse(raw, source: .appleMusic))
        #expect(s.state == .paused)
        #expect(s.duration == 180.5)
        #expect(s.repeating)
        #expect(s.isFavorite == true)
        #expect(s.artworkURL == nil)
    }

    @Test func rejectsStoppedAndGarbage() {
        #expect(MusicSnapshot.parse("stopped", source: .spotify) == nil)
        #expect(MusicSnapshot.parse("", source: .appleMusic) == nil)
        #expect(MusicSnapshot.parse(join(["stopped", "", "", "", "0", "0", "", "0", "", "false", "false"]), source: .spotify) == nil)
    }

    @Test func elapsedAdvancesOnlyWhilePlaying() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var s = MusicSnapshot(source: .spotify, state: .playing, title: "", artist: "", album: "", duration: 100,
                              position: 10, capturedAt: t0, volume: 0, artworkURL: nil, trackID: "",
                              shuffle: false, repeating: false, isFavorite: nil)
        #expect(s.elapsed(at: t0.addingTimeInterval(5)) == 15)
        #expect(s.elapsed(at: t0.addingTimeInterval(500)) == 100)
        s.state = .paused
        #expect(s.elapsed(at: t0.addingTimeInterval(5)) == 10)
    }
}

@Suite struct DominantColorTests {
    private func png(_ color: NSColor, grey: NSColor? = nil) -> Data {
        let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if let grey { ctx.setFillColor(grey.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16)) }
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: grey == nil ? 0 : 12, y: 0, width: grey == nil ? 16 : 4, height: 16))
        return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    }

    @Test func picksSaturatedColourOverGreyMajority() throws {
        let c = try #require(dominantColor(of: png(NSColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1),
                                                   grey: NSColor(white: 0.5, alpha: 1))))
        #expect(c.0 > 0.8 && c.1 < 0.2 && c.2 < 0.2)
    }

    @Test func fallsBackToAverageForGrey() throws {
        let c = try #require(dominantColor(of: png(NSColor(white: 0.5, alpha: 1))))
        #expect(abs(c.0 - 0.5) < 0.05)
    }
}

@Suite struct TimerStateTests {
    let t0 = Date(timeIntervalSince1970: 0)

    @Test func countdownRunsPausesResumes() {
        var s = TimerState(mode: .countdown, duration: 60)
        s.start(at: t0)
        #expect(s.display(at: t0.addingTimeInterval(10)) == 50)
        #expect(s.endDate == t0.addingTimeInterval(60))
        s.pause(at: t0.addingTimeInterval(10))
        #expect(s.display(at: t0.addingTimeInterval(100)) == 50)
        s.start(at: t0.addingTimeInterval(100))
        #expect(s.endDate == t0.addingTimeInterval(150))
        #expect(s.display(at: t0.addingTimeInterval(500)) == 0)
    }

    @Test func stopwatchCountsUpWithoutEnd() {
        var s = TimerState(mode: .stopwatch)
        s.start(at: t0)
        #expect(s.display(at: t0.addingTimeInterval(90)) == 90)
        #expect(s.endDate == nil)
        #expect(abs(s.progress(at: t0.addingTimeInterval(90)) - 0.5) < 0.001)
    }

    @Test func pomodoroAlternatesAndAutoStarts() {
        var s = TimerState(mode: .pomodoro)
        #expect(s.target == TimerState.workLength)
        s.start(at: t0)
        s.finish(at: t0.addingTimeInterval(TimerState.workLength))
        #expect(!s.pomodoroWork && s.isRunning)
        #expect(s.target == TimerState.breakLength)
    }
}

@Suite struct WidgetPackingTests {
    @Test func packsRowsOfThree() {
        let rows = WidgetStore.pack([("cal", 2), ("timer", 1), ("notes", 2), ("apps", 1), ("x", 1)])
        #expect(rows == [["cal", "timer"], ["notes", "apps"], ["x"]])
    }

    @Test func wideTileStartsNewRow() {
        #expect(WidgetStore.pack([("a", 1), ("b", 1), ("c", 2)]) == [["a", "b"], ["c"]])
        #expect(WidgetStore.pack([("huge", 5)]) == [["huge"]])
    }
}

@Suite struct BatteryEventTests {
    let t = [20, 10]
    func r(_ p: Int, ac: Bool, charging: Bool = false, charged: Bool = false) -> BatteryReading {
        BatteryReading(percent: p, onAC: ac, charging: charging, charged: charged)
    }

    @Test func firstReadingIsSilent() {
        #expect(BatteryEvent.events(from: nil, to: r(50, ac: true), thresholds: t).isEmpty)
    }

    @Test func plugAndUnplug() {
        #expect(BatteryEvent.events(from: r(50, ac: false), to: r(50, ac: true, charging: true), thresholds: t)
                == [.pluggedIn(charging: true)])
        #expect(BatteryEvent.events(from: r(50, ac: true), to: r(50, ac: false), thresholds: t) == [.unplugged])
    }

    @Test func chargingStartsLaterAndFinishes() {
        #expect(BatteryEvent.events(from: r(80, ac: true), to: r(80, ac: true, charging: true), thresholds: t)
                == [.chargingStarted])
        #expect(BatteryEvent.events(from: r(99, ac: true, charging: true), to: r(100, ac: true, charged: true), thresholds: t)
                == [.fullyCharged])
    }

    @Test func lowThresholdsOnlyOnBatteryAndOnce() {
        #expect(BatteryEvent.events(from: r(21, ac: false), to: r(20, ac: false), thresholds: t) == [.low(threshold: 20)])
        #expect(BatteryEvent.events(from: r(20, ac: false), to: r(19, ac: false), thresholds: t).isEmpty)
        #expect(BatteryEvent.events(from: r(11, ac: false), to: r(10, ac: false), thresholds: t) == [.low(threshold: 10)])
        #expect(BatteryEvent.events(from: r(25, ac: false), to: r(8, ac: false), thresholds: t) == [.low(threshold: 10)])
        #expect(BatteryEvent.events(from: r(21, ac: true), to: r(20, ac: true), thresholds: t).isEmpty)
    }
}

@Suite struct ActivityTests {
    @Test func popupQueueOrdersByPriorityAndReplacesKeys() {
        func p(_ key: String, _ prio: Int) -> ActivityPopup { ActivityPopup(key: key, priority: prio, symbol: "x", title: key) }
        var q: [ActivityPopup] = []
        q = ActivityCenter.enqueue(p("dl", 30), into: q)
        q = ActivityCenter.enqueue(p("low", 90), into: q)
        q = ActivityCenter.enqueue(p("bt", 60), into: q)
        q = ActivityCenter.enqueue(p("dl2", 30), into: q)
        #expect(q.map(\.key) == ["low", "bt", "dl", "dl2"])
        q = ActivityCenter.enqueue(p("bt", 60), into: q)
        #expect(q.map(\.key) == ["low", "bt", "dl", "dl2"])
    }


}

@Suite struct GestureTests {
    @Test func horizontalSwipeSkipsOncePerGesture() {
        var g = GestureRecognizer()
        #expect(g.feed(dx: 30, dy: 0, began: true, at: 0) == nil)
        #expect(g.feed(dx: 40, dy: 2, began: false, at: 0.05) == .next)
        #expect(g.feed(dx: 80, dy: 0, began: false, at: 0.1) == nil)      // same gesture
        #expect(g.feed(dx: -70, dy: 0, began: true, at: 0.2) == nil)      // cooldown
        #expect(g.feed(dx: -70, dy: 0, began: true, at: 1) == .previous)
    }

    @Test func invertAndVolume() {
        var g = GestureRecognizer()
        g.invert = true
        #expect(g.feed(dx: 70, dy: 0, began: true, at: 0) == .previous)
        g.verticalVolume = true
        #expect(g.feed(dx: 0, dy: 45, began: true, at: 2) == .volume(2 / 16))
        g.verticalVolume = false
        #expect(g.feed(dx: 0, dy: 45, began: true, at: 4) == nil)
    }
}

@Suite struct NotchMagnetTests {
    private let notch = CGRect(x: 100, y: 0, width: 200, height: 30)

    @Test func identityOutsideZone() {
        #expect(NotchMagnet.at(CGPoint(x: 200, y: 71), notch: notch) == .identity)
        #expect(NotchMagnet.at(CGPoint(x: 41, y: 15), notch: notch) == .identity)
        #expect(NotchMagnet.at(CGPoint(x: 1000, y: 500), notch: notch) == .identity)
    }

    @Test func scaleClampsInside() {
        let m = NotchMagnet.at(CGPoint(x: 200, y: 15), notch: notch)
        #expect(abs(m.scaleX - 1.06) < 1e-9 && abs(m.scaleY - 1.10) < 1e-9)
        let half = NotchMagnet.at(CGPoint(x: 200, y: 50), notch: notch) // 20 pt into the 40 pt zone
        #expect(abs(half.scaleX - 1.03) < 1e-9 && abs(half.scaleY - 1.05) < 1e-9)
    }

    @Test func offsetCappedWithSign() {
        let right = NotchMagnet.at(CGPoint(x: 330, y: 15), notch: notch)
        #expect(right.offsetX > 0 && right.offsetX <= 3)
        #expect(abs(NotchMagnet.at(CGPoint(x: 300, y: 15), notch: notch).offsetX - 3) < 1e-9)
        #expect(abs(NotchMagnet.at(CGPoint(x: 100, y: 15), notch: notch).offsetX + 3) < 1e-9)
        #expect(NotchMagnet.at(CGPoint(x: 200, y: 15), notch: notch).offsetX == 0)
    }
}

@MainActor @Suite struct PlayPauseFeedbackTests {
    @Test func showsIconForResultingState() {
        let f = PlayPauseFeedback(duration: .seconds(60))
        #expect(f.symbol == nil)
        f.show(playing: false)            // was playing, clicked: paused
        #expect(f.symbol == "pause.fill")
        f.show(playing: true)             // rapid second click: last wins
        #expect(f.symbol == "play.fill")
        #expect(f.clicks == 2)
    }

    @Test func clickRestartsTimer() async {
        let f = PlayPauseFeedback(duration: .seconds(60))
        f.show(playing: true)
        let first = f.task
        f.show(playing: false)
        #expect(first?.isCancelled == true)  // old timer cancelled, new one running
        await first?.value
        #expect(f.symbol == "pause.fill")    // cancelled timer must not clear the new icon
        f.task?.cancel()
    }

    @Test func clearsAfterDuration() async {
        let f = PlayPauseFeedback(duration: .milliseconds(20))
        f.show(playing: true)
        await f.task?.value
        #expect(f.symbol == nil)
    }
}

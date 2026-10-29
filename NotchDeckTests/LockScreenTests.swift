import AppKit
import Testing
@testable import NotchDeck

private func snap(_ state: PlaybackState = .playing) -> MusicSnapshot {
    MusicSnapshot(source: .spotify, state: state, title: "Song", artist: "Artist", album: "Album",
                  duration: 187, position: 0, capturedAt: .now, volume: 50, artworkURL: nil,
                  trackID: "1", shuffle: false, repeating: false, isFavorite: nil)
}

@Suite struct LockStateTests {
    @Test func lockAndUnlock() {
        var s = LockState()
        #expect(!s.onLockScreen)
        s.apply(.locked)
        #expect(s.onLockScreen)
        s.apply(.unlocked)
        #expect(!s.onLockScreen)
    }

    @Test func fastUserSwitchHidesUntilSessionReturns() {
        var s = LockState()
        s.apply(.locked)
        s.apply(.sessionResigned)
        #expect(!s.onLockScreen)
        s.apply(.resynced(locked: true))
        #expect(s.onLockScreen)
    }

    @Test func wakeResyncFixesMissedUnlock() {
        var s = LockState()
        s.apply(.locked)
        s.apply(.resynced(locked: false))
        #expect(!s.onLockScreen)
    }

    @Test func showsPlayerRules() {
        var s = LockState()
        #expect(!s.showsPlayer(enabled: true, track: snap(), showWhenPaused: true)) // unlocked
        s.apply(.locked)
        #expect(s.showsPlayer(enabled: true, track: snap(), showWhenPaused: false))
        #expect(!s.showsPlayer(enabled: false, track: snap(), showWhenPaused: true))
        #expect(!s.showsPlayer(enabled: true, track: nil, showWhenPaused: true)) // nothing loaded
        #expect(s.showsPlayer(enabled: true, track: snap(.paused), showWhenPaused: true))
        #expect(!s.showsPlayer(enabled: true, track: snap(.paused), showWhenPaused: false))
    }
}

@MainActor @Suite struct LockRevealTests {
    @Test func duplicateLockEventDoesNotRevealTwice() {
        let monitor = LockStateMonitor()
        var reveals = 0
        monitor.onChange = { old, new in if new.onLockScreen, !old.onLockScreen { reveals += 1 } }
        monitor.send(.locked)
        monitor.send(.locked)
        monitor.send(.resynced(locked: true)) // wake after lock + sleep
        #expect(reveals == 1)
    }

    @Test func revealInFlightAbsorbsTheNextOne() {
        // The first call may itself be absorbed by the app's launch reveal; either way one is in flight.
        ActivityCenter.shared.reveal(hold: 0)
        #expect(!ActivityCenter.shared.reveal(hold: 0))
    }
}

@Suite struct SkyLightResolutionTests {
    @Test func missingSymbolDisablesPresenter() {
        let resolve: (String) -> UnsafeMutableRawPointer? = { $0 == "SLSShowSpaces" ? nil : UnsafeMutableRawPointer(bitPattern: 0x1) }
        #expect(SkyLightAPI.load(resolve: resolve) == nil)
        #expect(SkyLightAPI.missingSymbols(resolve: resolve) == ["SLSShowSpaces"])
    }

    @MainActor @Test func nullPresenterIsInert() {
        let p = NullLockScreenPresenter(reason: "x")
        #expect(!p.isSupported)
        #expect(p.lastError == "x")
        p.show([]); p.hide()
    }
}

@Suite struct LockScreenFormattingTests {
    @Test func remaining() {
        #expect(remainingTime(elapsed: 0, duration: 187) == "-3:07")
        #expect(remainingTime(elapsed: 60, duration: 187) == "-2:07")
        #expect(remainingTime(elapsed: 200, duration: 187) == "-0:00")
        #expect(remainingTime(elapsed: 0, duration: 0) == "-0:00")
    }

    @Test func hideDetailsModes() {
        let s = snap()
        #expect(LockScreenText(s, mode: .show) == LockScreenText(title: "Song", artist: "Artist", showsCover: true))
        #expect(LockScreenText(s, mode: .coverAndControls) == LockScreenText(title: nil, artist: nil, showsCover: true))
        let generic = LockScreenText(s, mode: .genericLabel)
        #expect(generic.artist == nil && !generic.showsCover)
        #expect(generic.title != "Song")
    }
}

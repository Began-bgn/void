import SwiftUI
import Observation
import UserNotifications

/// Pure timer/stopwatch/pomodoro state; time is derived from dates, nothing ticks.
struct TimerState: Codable, Equatable {
    enum Mode: String, Codable { case countdown, stopwatch, pomodoro }

    static let workLength: TimeInterval = 25 * 60
    static let breakLength: TimeInterval = 5 * 60

    var mode: Mode = .countdown
    var duration: TimeInterval = 5 * 60
    var pomodoroWork = true
    var startedAt: Date?
    var accumulated: TimeInterval = 0

    var isRunning: Bool { startedAt != nil }
    var isIdle: Bool { !isRunning && accumulated == 0 }

    /// Length of the current countdown; nil for the stopwatch.
    var target: TimeInterval? {
        switch mode {
        case .countdown: duration
        case .pomodoro: pomodoroWork ? Self.workLength : Self.breakLength
        case .stopwatch: nil
        }
    }

    func elapsed(at now: Date) -> TimeInterval {
        accumulated + (startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    /// Remaining time for countdowns, elapsed time for the stopwatch.
    func display(at now: Date) -> TimeInterval {
        target.map { max(0, $0 - elapsed(at: now)) } ?? elapsed(at: now)
    }

    /// 0…1 of the countdown; the stopwatch sweeps once a minute.
    func progress(at now: Date) -> Double {
        guard let target else { return elapsed(at: now).truncatingRemainder(dividingBy: 60) / 60 }
        return min(1, elapsed(at: now) / target)
    }

    var endDate: Date? {
        guard let startedAt, let target else { return nil }
        return startedAt.addingTimeInterval(target - accumulated)
    }

    mutating func start(at now: Date) { if !isRunning { startedAt = now } }
    mutating func pause(at now: Date) { accumulated = elapsed(at: now); startedAt = nil }
    mutating func reset() { startedAt = nil; accumulated = 0 }

    /// Countdown ends; a pomodoro flips work/break and starts the next phase.
    mutating func finish(at now: Date) {
        reset()
        if mode == .pomodoro {
            pomodoroWork.toggle()
            startedAt = now
        }
    }
}

@MainActor @Observable
final class TimerModel {
    static let shared = TimerModel()

    private(set) var state: TimerState
    /// When the last countdown finished (drives the finish flash).
    private(set) var finishedAt: Date?

    @ObservationIgnored private var finishTask: Task<Void, Never>?
    private let notificationID = "com.notchdeck.timer"

    private init() {
        state = WidgetStorage.load("timer", as: TimerState.self) ?? TimerState()
        schedule()
    }

    func start() {
        requestNotificationPermission()
        update { $0.start(at: .now) }
    }
    func pause() { update { $0.pause(at: .now) } }
    func reset() { update { $0.reset() } }

    func setCountdown(seconds: TimeInterval) {
        update { $0 = TimerState(mode: .countdown, duration: seconds) }
    }
    func setMode(_ mode: TimerState.Mode) {
        update { $0 = TimerState(mode: mode, duration: $0.duration) }
    }

    private func update(_ change: (inout TimerState) -> Void) {
        change(&state)
        WidgetStorage.save(state, "timer")
        schedule()
    }

    /// One sleeping task until the end date, plus a system notification in case the app is gone.
    private func schedule() {
        finishTask?.cancel(); finishTask = nil
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationID])
        guard let end = state.endDate else { return }

        let wait = end.timeIntervalSinceNow
        if wait <= 0 { finish(); return }

        let content = UNMutableNotificationContent()
        content.title = state.mode == .pomodoro
            ? (state.pomodoroWork ? String(localized: "Time for a break") : String(localized: "Back to work"))
            : String(localized: "Timer finished")
        content.sound = .default
        center.add(UNNotificationRequest(identifier: notificationID, content: content,
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)))

        finishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private func finish() {
        finishedAt = .now
        NSSound(named: "Glass")?.play()
        if SettingsStore.shared.activityTimer {
            let pomodoro = state.mode == .pomodoro
            ActivityCenter.shared.post(.init(
                key: "timer", priority: ActivityPopup.Priority.timer, symbol: "timer", color: .orange,
                title: pomodoro ? (state.pomodoroWork ? String(localized: "Time for a break") : String(localized: "Back to work"))
                                : String(localized: "Timer finished"),
                pulse: true))
        }
        update { $0.finish(at: .now) }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

extension Color {
    /// Clock app timer colours (dark appearance system orange / green).
    static let clockOrange = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let clockGreen = Color(red: 0.19, green: 0.82, blue: 0.35)
}

struct TimerWidget: NotchWidget {
    static let kind = "timer"
    static let title = String(localized: "Timer")
    static let symbol = "timer"
    static let span = 1

    let tint: Color
    private let model = TimerModel.shared
    @State private var choosing = false
    @State private var pickMinutes = 5
    @State private var pickSeconds = 0

    init(tint: Color) { self.tint = tint }

    var body: some View {
        let state = model.state
        if choosing { presets } else { clock(state) }
    }

    /// Preset grid shown in place of the clock.
    /// Mode chips plus Clock-style minute/second wheels; ✓ sets the countdown.
    private var presets: some View {
        VStack(spacing: 6) {
            HStack(spacing: 3) {
                chip(String(localized: "Stopwatch")) { model.setMode(.stopwatch) }
                chip(String(localized: "Pomodoro")) { model.setMode(.pomodoro) }
            }
            HStack(spacing: 2) {
                WheelPicker(value: $pickMinutes, range: 0..<100, unit: "min")
                WheelPicker(value: $pickSeconds, range: 0..<60, unit: "sec")
                Button {
                    model.setCountdown(seconds: TimeInterval(pickMinutes * 60 + pickSeconds))
                    withAnimation(.easeInOut(duration: 0.18)) { choosing = false }
                } label: {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 16))
                        .foregroundStyle(Color.clockGreen)
                }
                .buttonStyle(.plain)
                .disabled(pickMinutes == 0 && pickSeconds == 0)
                .accessibilityLabel("Set timer")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
        .onAppear {
            let d = Int(model.state.duration)
            pickMinutes = min(d / 60, 99); pickSeconds = d % 60
        }
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            withAnimation(.easeInOut(duration: 0.18)) { choosing = false }
        } label: {
            Text(title).font(.system(size: 9, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity).frame(height: 16)
                .background(.white.opacity(0.1), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
    }

    private func clock(_ state: TimerState) -> some View {
        TimelineView(.periodic(from: .now, by: state.isRunning ? 0.5 : 3600)) { ctx in
            VStack(spacing: 6) {
                ZStack {
                    Circle().stroke(.white.opacity(0.12), lineWidth: 4)
                    Circle().trim(from: 0, to: state.progress(at: ctx.date))
                        .stroke(Color.clockOrange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(formatTime(state.display(at: ctx.date)))
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        Text(modeLabel(state)).font(.system(size: 7.5)).opacity(0.55)
                    }
                    .foregroundStyle(.white)
                }
                .frame(width: 58, height: 58)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(modeLabel(state))
                .accessibilityValue(formatTime(state.display(at: ctx.date)))

                controls(state)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func controls(_ state: TimerState) -> some View {
        HStack(spacing: 12) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { choosing = true } } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .accessibilityLabel("Timer presets")

            Button { state.isRunning ? model.pause() : model.start() } label: {
                Image(systemName: state.isRunning ? "pause.fill" : "play.fill").font(.system(size: 14))
                    .foregroundStyle(state.isRunning ? Color.clockOrange : Color.clockGreen)
            }
            .accessibilityLabel(state.isRunning ? "Pause timer" : "Start timer")

            Button { model.reset() } label: { Image(systemName: "arrow.counterclockwise") }
                .disabled(state.isIdle)
                .accessibilityLabel("Reset timer")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white.opacity(0.85))
    }

    private func modeLabel(_ s: TimerState) -> String {
        switch s.mode {
        case .countdown: String(localized: "Timer")
        case .stopwatch: String(localized: "Stopwatch")
        case .pomodoro: s.pomodoroWork ? String(localized: "Focus") : String(localized: "Break")
        }
    }
}

/// Clock-app style scroll wheel: snaps to rows, the centred value is selected.
struct WheelPicker: View {
    @Binding var value: Int
    let range: Range<Int>
    let unit: String
    @State private var position: Int?
    private let row: CGFloat = 17

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(range, id: \.self) { n in
                    Text(String(format: "%02d", n))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(n == value ? 1 : 0.35))
                        .frame(maxWidth: .infinity).frame(height: row)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.vertical, row, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $position, anchor: .center)
        .frame(height: row * 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.1)).frame(height: row))
        .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .trailing) {
            Text(unit).font(.system(size: 7, weight: .medium)).foregroundStyle(.white.opacity(0.5)).padding(.trailing, 1)
        }
        .onAppear { position = value }
        .onChange(of: position) { _, new in if let new { value = new } }
        .accessibilityElement()
        .accessibilityLabel(unit == "min" ? "Minutes" : "Seconds")
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: value = min(value + 1, range.upperBound - 1)
            case .decrement: value = max(value - 1, range.lowerBound)
            @unknown default: break
            }
            position = value
        }
    }
}

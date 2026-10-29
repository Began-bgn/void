import SwiftUI
import EventKit
import Observation

@MainActor @Observable
final class CalendarModel {
    static let shared = CalendarModel()

    struct Event: Identifiable {
        let id: String
        let title: String
        let start: Date
        let isAllDay: Bool
        let color: Color
    }

    private(set) var status = EKEventStore.authorizationStatus(for: .event)
    /// Events per start-of-day, for the days the week strip shows.
    private(set) var byDay: [Date: [Event]] = [:]

    /// The strip: a week back to three weeks ahead.
    static var stripDays: [Date] {
        let cal = Calendar.current, today = cal.startOfDay(for: .now)
        return (-7...21).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
    }

    func events(on day: Date) -> [Event] { byDay[Calendar.current.startOfDay(for: day)] ?? [] }

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var hasAccess: Bool { status == .fullAccess }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] _, _ in
            Task { @MainActor in
                self?.status = EKEventStore.authorizationStatus(for: .event)
                self?.refresh()
            }
        }
    }

    func refresh() {
        status = EKEventStore.authorizationStatus(for: .event)
        guard hasAccess else { byDay = [:]; return }
        let cal = Calendar.current, days = Self.stripDays
        guard let first = days.first, let last = days.last.flatMap({ cal.date(byAdding: .day, value: 1, to: $0) }) else { return }
        var map: [Date: [Event]] = [:]
        for e in store.events(matching: store.predicateForEvents(withStart: first, end: last, calendars: nil))
            .sorted(by: { $0.startDate < $1.startDate }) {
            let event = Event(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "",
                              start: e.startDate, isAllDay: e.isAllDay, color: Color(cgColor: e.calendar.cgColor))
            // Every day the event touches (multi-day events show on each).
            var day = max(cal.startOfDay(for: e.startDate), first)
            while day < min(e.endDate, last) || day == cal.startOfDay(for: e.startDate) {
                map[day, default: []].append(event)
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        byDay = map
    }
}

struct CalendarWidget: NotchWidget {
    static let kind = "calendar"
    static let title = String(localized: "Calendar")
    static let symbol = "calendar"
    static let span = 2

    let tint: Color
    private let model = CalendarModel.shared

    @State private var selected = Calendar.current.startOfDay(for: .now)
    @State private var position: Date?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: -1) {
                    Text(selected, format: .dateTime.month(.abbreviated))
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    Text(selected, format: .dateTime.year())
                        .font(.system(size: 15)).foregroundStyle(.white.opacity(0.5))
                }
                .frame(width: 44, alignment: .leading)
                strip
            }
            .frame(height: 36)
            if model.hasAccess { dayEvents } else { access }
        }
        .task { model.refresh() }
    }

    /// Horizontally scrolling days, fading out at both edges; today in a blue circle.
    private var strip: some View {
        let today = Calendar.current.startOfDay(for: .now)
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 2) {
                ForEach(CalendarModel.stripDays, id: \.self) { day in
                    let isSelected = day == selected
                    Button { withAnimation(.smooth(duration: 0.25)) { selected = day } } label: {
                        VStack(spacing: 3) {
                            Text(day, format: .dateTime.weekday(.abbreviated))
                                .font(.system(size: 8.5, weight: .medium))
                                .foregroundStyle(.white.opacity(isSelected ? 1 : 0.6))
                            Text(day, format: .dateTime.day())
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white.opacity(isSelected || day == today ? 1 : 0.75))
                                .frame(width: 19, height: 19)
                                .background { if day == today { Circle().fill(.blue) } }
                        }
                        .frame(width: 27, height: 36)
                        .background {
                            if isSelected { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.blue.opacity(0.25)) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $position, anchor: .center)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.15),
                                     .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .onAppear { position = today }
    }

    @ViewBuilder private var dayEvents: some View {
        let events = model.events(on: selected)
        if events.isEmpty {
            VStack(spacing: 2) {
                Image(systemName: "calendar.badge.checkmark")
                    .font(.system(size: 16)).symbolRenderingMode(.hierarchical).foregroundStyle(.white.opacity(0.6))
                Text(Calendar.current.isDateInToday(selected) ? "No events today" : "No events")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                Text("Enjoy your free time!").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(events.prefix(2)) { e in
                    HStack(alignment: .top, spacing: 5) {
                        RoundedRectangle(cornerRadius: 1).fill(e.color).frame(width: 2, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.title).font(.system(size: 10)).lineLimit(1).foregroundStyle(.white)
                            Text(e.isAllDay ? String(localized: "All day") : e.start.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 8.5)).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if events.count > 2 {
                    Text("+\(events.count - 2) more").font(.system(size: 8.5)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var access: some View {
        if model.status == .notDetermined {
            Button("Allow access") { model.requestAccess() }
                .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(tint)
        } else {
            Text("No calendar access").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            }
            .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(tint)
        }
    }
}

import MoobilityCore
import SwiftUI

/// The "+ When" menu. Holiday, season and every day apply on click; the "…" items open a sheet.
struct WhenPopover: View {
    let photoTitle: String
    let southern: Bool
    let onPick: (TimingRule) -> Void

    private enum Section { case holiday, season }
    private enum SheetKind: Int, Identifiable { case yearly, weekly, allHolidays; var id: Int { rawValue } }
    @State private var open: Section? = .holiday
    @State private var leadDays = 0
    @State private var sheet: SheetKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Show “\(photoTitle)” …").fontWeight(.semibold).padding(.bottom, 4)

            row("Holiday", chevron: open == .holiday) { open = open == .holiday ? nil : .holiday }
            if open == .holiday {
                let upcoming = Holidays.upcoming(from: today)
                ForEach(upcoming.prefix(4), id: \.holiday.id) { item in
                    subrow(item.holiday.name, detail: dateText(item)) { pick(holiday: item.holiday.id) }
                }
                subrow("More holidays…", detail: "") { sheet = .allHolidays }
                Stepper(value: $leadDays, in: 0...30) {
                    Text("Start showing \(leadDays) days before").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 10)
                .padding(.top, 4)
            }
            Divider().padding(.vertical, 3)

            row("Season", chevron: open == .season) { open = open == .season ? nil : .season }
            if open == .season {
                ForEach(Season.allCases, id: \.self) { season in
                    let dates = season.dates(southern: southern)
                    subrow(season.title, detail: "") { onPick(.yearly(start: dates.start, end: dates.end)) }
                }
            }
            row("Every year on these dates…") { sheet = .yearly }
            row("Every week on these days…") { sheet = .weekly }
            row("Every day (when nothing else is scheduled)") { onPick(.everyDay) }
        }
        .padding(10)
        .frame(width: 300)
        .sheet(item: $sheet) { kind in
            switch kind {
            case .yearly:
                RuleEditorSheet(initial: .yearly(start: MonthDay(month: today.month, day: today.day),
                                                 end: MonthDay(month: today.month, day: today.day)),
                                onSave: onPick, onRemove: nil)
            case .weekly:
                RuleEditorSheet(initial: .weekly(days: [today.weekday], window: .allDay), onSave: onPick, onRemove: nil)
            case .allHolidays:
                AllHolidaysSheet { id in pick(holiday: id) }
            }
        }
    }

    private func pick(holiday id: HolidayID) { onPick(.holiday(id: id, leadDays: leadDays)) }

    private func dateText(_ item: (holiday: Holiday, span: ClosedRange<CivilDay>)) -> String {
        (item.holiday.approximate ? "≈ " : "") + item.span.shortText
    }

    private func row(_ title: String, chevron: Bool? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let chevron { Image(systemName: chevron ? "chevron.down" : "chevron.right").font(.caption2) }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }

    private func subrow(_ title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
            .padding(.leading, 10)
        }
        .buttonStyle(.plain)
    }
}

private struct AllHolidaysSheet: View {
    let onPick: (HolidayID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        let items = Holidays.all.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        VStack(alignment: .leading) {
            TextField("Search holidays", text: $search).textFieldStyle(.roundedBorder)
            List(items, id: \.id) { holiday in
                Button {
                    onPick(holiday.id)
                    dismiss()
                } label: {
                    HStack {
                        Text(holiday.name)
                        Spacer()
                        Text(nextText(holiday)).font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
        .frame(width: 360, height: 420)
    }

    private func nextText(_ holiday: Holiday) -> String {
        guard let span = Holidays.nextSpan(holiday.id, from: today) else {
            return Holidays.lastKnownYear(holiday.id).map { "No dates after \($0)" } ?? ""
        }
        return (holiday.approximate ? "≈ " : "") + span.shortText
    }
}

/// Edits one rule of any kind. `onRemove` is nil when the rule is new.
struct RuleEditorSheet: View {
    let initial: TimingRule
    let onSave: (TimingRule) -> Void
    let onRemove: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var startMonth = 1
    @State private var startDay = 1
    @State private var endMonth = 1
    @State private var endDay = 1
    @State private var days: Set<Int> = []
    @State private var allDay = true
    @State private var startTime = RuleEditorSheet.clock(minute: 540)
    @State private var endTime = RuleEditorSheet.clock(minute: 1020)
    @State private var leadDays = 0

    private static let months = Calendar(identifier: .gregorian).shortMonthSymbols
    private static let dayLetters: [(Int, String)] = [(1, "S"), (2, "M"), (3, "T"), (4, "W"), (5, "T"), (6, "F"), (7, "S")]
    private static let monthLengths = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(heading).font(.headline)
            editor
            HStack {
                if let onRemove {
                    Button("Remove", role: .destructive) {
                        onRemove()
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") {
                    onSave(edited)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(16)
        .frame(width: 400)
        .onAppear(perform: load)
    }

    private var heading: String {
        switch initial {
        case .yearly: "Every year on these dates"
        case .weekly: "Every week on these days"
        case let .holiday(id, _): Holidays.all.first { $0.id == id }?.name ?? "Holiday"
        case .everyDay: "Every day"
        }
    }

    @ViewBuilder private var editor: some View {
        switch initial {
        case .yearly:
            dateRow("From", month: $startMonth, day: $startDay)
            dateRow("To", month: $endMonth, day: $endDay)
        case .weekly:
            HStack(spacing: 6) {
                ForEach(Self.dayLetters, id: \.0) { number, letter in
                    Toggle(letter, isOn: Binding(get: { days.contains(number) }, set: { on in
                        if on { days.insert(number) } else { days.remove(number) }
                    }))
                    .toggleStyle(.button)
                }
            }
            Toggle("All day", isOn: $allDay)
            if !allDay {
                HStack {
                    DatePicker("From", selection: $startTime, displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: $endTime, displayedComponents: .hourAndMinute)
                }
            }
        case .holiday:
            Stepper(value: $leadDays, in: 0...30) { Text("Start showing \(leadDays) days before") }
        case .everyDay:
            Text("Shows when nothing else is scheduled.").foregroundStyle(.secondary)
        }
    }

    private func dateRow(_ label: String, month: Binding<Int>, day: Binding<Int>) -> some View {
        HStack {
            Text(label).frame(width: 44, alignment: .leading)
            Picker("Month", selection: month) {
                ForEach(1...12, id: \.self) { Text(Self.months[$0 - 1]).tag($0) }
            }
            .labelsHidden()
            Picker("Day", selection: day) {
                ForEach(1...Self.monthLengths[month.wrappedValue - 1], id: \.self) { Text("\($0)").tag($0) }
            }
            .labelsHidden()
        }
        .onChange(of: month.wrappedValue) { _, newMonth in
            day.wrappedValue = min(day.wrappedValue, Self.monthLengths[newMonth - 1])
        }
    }

    private var isValid: Bool {
        guard case .weekly = initial else { return true }
        if days.isEmpty { return false }
        return allDay || Self.minute(of: startTime) != Self.minute(of: endTime)
    }

    private var edited: TimingRule {
        switch initial {
        case .yearly:
            .yearly(start: MonthDay(month: startMonth, day: startDay), end: MonthDay(month: endMonth, day: endDay))
        case .weekly:
            .weekly(days: days, window: allDay ? .allDay : .timed(start: Self.minute(of: startTime), end: Self.minute(of: endTime)))
        case let .holiday(id, _):
            .holiday(id: id, leadDays: leadDays)
        case .everyDay:
            .everyDay
        }
    }

    private func load() {
        switch initial {
        case let .yearly(start, end):
            startMonth = start.month; startDay = start.day
            endMonth = end.month; endDay = end.day
        case let .weekly(selected, window):
            days = selected
            if case let .timed(start, end) = window {
                allDay = false
                startTime = Self.clock(minute: start)
                endTime = Self.clock(minute: end)
            }
        case let .holiday(_, lead):
            leadDays = lead
        case .everyDay:
            break
        }
    }

    private static func clock(minute: Int) -> Date {
        Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
    }

    private static func minute(of date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}

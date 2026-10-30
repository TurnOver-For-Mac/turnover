// SPDX-License-Identifier: GPL-3.0-or-later
// Calendar (17 Oct 2026, the Apple apps sweep: the roadmap "Apple apps: all of them"). VoiceOver reads Calendar's
// month view as a grid of forty-two day lists and each event as a long sentence; getting to "what's on Thursday"
// takes many keys. TurnOver reads it as a diary: Left and Right go a day at a time ("Thursday 22 October, 2 events"),
// Up and Down go through that day's events ("14:00 to 15:00, Team meeting, Room 2, 1 of 2"), Option Up and
// Down a week at a time, and Return opens the event. Moving past the view's first or last day turns the page (the
// view's own previous and next buttons). Month, week and day views alike.
//
// What Calendar gives accessibility (probe, 17 Oct 2026): the view is a group (identifier month-container,
// week-container or day-container); each day is an AXList (month: titled "Monday 28 September", "Today, Saturday 17
// October"; week and day: identifier day-column-2026-10-17, described the same way); each event is an AXStaticText
// whose description is "Title, place. Starts on 4 May 2030 at 14:00 and ends at 15:00." or "Title. 1 May
// 2030, All-Day", and whose help names its calendar.
import Foundation
import ApplicationServices

final class CalendarAppModule: AppModule {
    static let bundleID = "com.apple.iCal"
    static let containers = ["month-container", "week-container", "day-container"]

    /// Where the reading is: a date, and an event on it (nil: the day itself).
    private var current = Calendar.current.startOfDay(for: Date())
    private var eventIndex: Int?
    /// When TurnOver last moved (a page turned, an event opened): Calendar moves its own focus after it and the
    /// view, the month and the day were read again on top of TurnOver's words (week and day views, 17 Oct 2026).
    private var lastOwnMove = Date.distantPast
    /// Return opened an event: waiting for its details to take the focus, then for the focus to come back.
    private enum Opened { case no, waiting, showing }
    private var opened = Opened.no

    required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        let cat = "Calendar"
        script("cal_nextDay", String(localized: "The next day, and how many events it has", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:rightArrow"], category: cat) { [weak self] g in self?.moveDays(1, g) }.isAvailable = { [weak self] in self?.inView() == true }
        script("cal_previousDay", String(localized: "The previous day", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:leftArrow"], category: cat) { [weak self] g in self?.moveDays(-1, g) }.isAvailable = { [weak self] in self?.inView() == true }
        script("cal_nextWeek", String(localized: "The same day next week", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:option+downArrow"], category: cat) { [weak self] g in self?.moveDays(7, g) }.isAvailable = { [weak self] in self?.inView() == true }
        script("cal_previousWeek", String(localized: "The same day last week", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:option+upArrow"], category: cat) { [weak self] g in self?.moveDays(-7, g) }.isAvailable = { [weak self] in self?.inView() == true }
        script("cal_nextEvent", String(localized: "The day's next event", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:downArrow"], category: cat) { [weak self] g in self?.moveEvent(1, g) }.isAvailable = { [weak self] in self?.inView() == true }
        script("cal_previousEvent", String(localized: "The day's previous event", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:upArrow"], category: cat) { [weak self] g in self?.moveEvent(-1, g) }.isAvailable = { [weak self] in self?.inView() == true }
        script("cal_open", String(localized: "Opens the event (its details)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:enter"], category: cat) { [weak self] g in self?.openEvent(g) }.isAvailable = { [weak self] in self?.inView() == true && self?.eventIndex != nil }
        script("cal_today", String(localized: "Back to today", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+t"], category: cat) { [weak self] g in
            g.send()
            guard let self else { return }
            self.current = Calendar.current.startOfDay(for: Date()); self.eventIndex = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.sayDay() }
        }.isAvailable = { [weak self] in self?.inView() == true }
        // The new event box (Command N, or Return on a day): Tab and Shift-Tab between its fields. Calendar's own Tab
        // left the box for the month and closed it, with only the title typed (18 Oct 2026: "struggling to add
        // an event"); macOS moves between all controls only with Keyboard navigation on.
        script("cal_boxNext", String(localized: "The event box's next field", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:tab"], category: cat) { [weak self] _ in self?.moveInBox(1) }
            .isAvailable = { [weak self] in self?.eventBox() != nil }
        script("cal_boxPrevious", String(localized: "The event box's previous field", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+tab"], category: cat) { [weak self] _ in self?.moveInBox(-1) }
            .isAvailable = { [weak self] in self?.eventBox() != nil }
        // The box's buttons can't take the keyboard focus (probe): Tab rests on one by name, Return or Space presses it.
        script("cal_boxPress", String(localized: "Presses the event box's button", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:enter", "kb:space"], category: cat) { [weak self] _ in
            guard let self else { return }
            if self.onDone() { self.saveFromDone() } else { self.pressBoxButton() }
        }.isAvailable = { [weak self] in self?.onDone() == true || self?.boxButton() != nil }
        // Return in the quick entry, the title or the place: Calendar saves and closes the box; TurnOver says what was saved and goes to it.
        script("cal_boxSave", String(localized: "Saves the event, says it and goes to its day", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:enter"], category: cat) { [weak self] g in
            guard let self, let box = self.eventBox() else { g.send(); return }
            self.saveBox(box) { g.send() }
        }.isAvailable = { [weak self] in
            guard let self, self.boxButton() == nil, !self.onDone(),
                  let f = AXUIElementCreateApplication(self.pid).element(kAXFocusedUIElementAttribute) else { return false }
            // The quick entry too: as it's typed in, Calendar fills in the title and the date (probe), so they're known.
            return ["title-field", "location-field", "magic-compose-field"].contains(f.string(kAXIdentifierAttribute) ?? "") && self.popover(holding: f) != nil
        }
    }

    // MARK: The new event box

    /// The box's button Tab rests on (it can't hold the focus itself), and the field that had the focus then.
    private var restingOn: AXUIElement?
    private var restingFrom: AXUIElement?
    /// Tab rests on Done, after the box's last part.
    private var restingDone = false
    /// The opened event's box whose title was given the focus (once per box).
    private var titledBox: AXUIElement?
    /// When a field was focused from the quick entry, whose leaving builds the box again.
    private var boxRebuiltAt = Date.distantPast

    private func popover(holding element: AXUIElement) -> AXUIElement? {
        var e: AXUIElement? = element; var hops = 0
        while let x = e, hops < 8 { if x.role == "AXPopover" { return x }; e = x.element(kAXParentAttribute); hops += 1 }
        return nil
    }

    /// The event box (an AXPopover) the keyboard is in: by the focus, or by the button Tab rests on.
    private func eventBox() -> AXUIElement? {
        if let f = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute), let p = popover(holding: f) { return p }
        if let b = boxButton() { return popover(holding: b) }
        return nil
    }

    /// The button Tab rests on, while the focus is still where it was and the box is still open.
    private func boxButton() -> AXUIElement? {
        guard let b = restingOn else { return nil }
        let f = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute)
        guard !b.role.isEmpty, popover(holding: b) != nil, f == nil || restingFrom == nil || f!.isSame(restingFrom!) || f!.role == "AXWindow" else {
            restingOn = nil; restingFrom = nil; return nil
        }
        return b
    }

    /// The box's fields in order: the quick entry, the title, date and time, alerts, location, video call, invitees,
    /// the calendar, notes, and Event or Reminder.
    private func boxFields(_ box: AXUIElement) -> [AXUIElement] {
        // In reading order (depth first): level by level put Event and Reminder first. An opened event's box starts with
        // an "Edit Description" button (probe) that did nothing heard; it's left out.
        var out: [AXUIElement] = []
        var seen = 0
        func walk(_ e: AXUIElement) {
            seen += 1; guard seen < 200 else { return }
            if Self.boxRoles.contains(e.role),
               (e.attr(kAXEnabledAttribute) as? Bool) != false, !["Delete", "Edit Description"].contains(e.string(kAXTitleAttribute) ?? "") { out.append(e); return }
            for c in e.elements(kAXChildrenAttribute) { walk(c) }
        }
        walk(box)
        return out
    }
    static let boxRoles: Set<String> = ["AXTextField", "AXTextArea", "AXButton", "AXPopUpButton", "AXRadioButton", "AXCheckBox", "AXDateTimeArea", "AXComboBox"]
    static let typedRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXDateTimeArea"]

    private func moveInBox(_ by: Int) {
        guard let box = eventBox() else { return }
        let fields = boxFields(box)
        guard !fields.isEmpty else { return }
        // Where Tab is: Done (after the last field), the button it rests on, or the field holding the focus (or
        // holding its editor: the quick entry).
        var at: Int?
        if onDone() { at = fields.count }
        if at == nil, let b = boxButton() { at = fields.firstIndex { $0.isSame(b) } }
        let focus = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute)
        if at == nil, let f = focus {
            var e: AXUIElement? = f; var hops = 0
            while let x = e, at == nil, hops < 4 { at = fields.firstIndex { $0.isSame(x) }; e = x.element(kAXParentAttribute); hops += 1 }
        }
        let next = (at ?? (by > 0 ? -1 : fields.count + 1)) + by
        guard next >= 0, next <= fields.count else { Tones.edge(); return }
        restingOn = nil; restingDone = false; restingFrom = nil
        // Done: Calendar's box has no button to finish with (18 Oct 2026); Return in the title saves.
        if next == fields.count {
            restingFrom = focus; restingDone = true
            Speech.cancel(); Speech.speakMessage(String(localized: "Done, button", comment: "Spoken message"))
            return
        }
        let target = fields[next]
        if Self.typedRoles.contains(target.role) {
            // Already holding the focus (Shift-Tab back from a button after it): said, as the focus won't change.
            if let f = focus, f.isSame(target) { Speech.cancel(); Speech.speakObject(ObjectFactory.make(target), reason: .focus); return }
            focusField(target, id: target.string(kAXIdentifierAttribute), retry: true)
        } else {
            // A button: said, and remembered for Return; the focus stays put.
            restingFrom = focus
            restingOn = target
            Speech.cancel()
            Speech.speakObject(ObjectFactory.make(target), reason: .focus)
        }
    }

    /// Tab rests on Done, with the focus still where it was and the box still open.
    private func onDone() -> Bool {
        guard restingDone else { return false }
        let f = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute)
        guard let f, popover(holding: f) != nil, restingFrom.map({ f.isSame($0) }) ?? true else { restingDone = false; return false }
        return true
    }

    // MARK: Saving

    struct BoxSummary { let title: String; let start: Date?; let allDay: Bool }

    /// The event as the box has it: its title and when it starts.
    private func boxSummary(_ box: AXUIElement) -> BoxSummary {
        let titleField = Self.find(id: "title-field", in: box)
        var title = titleField?.string(kAXValueAttribute) ?? ""
        if title.isEmpty { title = titleField?.string(kAXPlaceholderValueAttribute) ?? "New Event" }
        let allDay = (Self.find(id: "allday-checkbox", in: box)?.attr(kAXValueAttribute) as? NSNumber)?.boolValue
        if let start = Self.find(id: "start-datepicker", in: box)?.attr(kAXValueAttribute) as? Date {
            return BoxSummary(title: title, start: start, allDay: allDay ?? false)
        }
        // Not opened: the date button says "2 Nov 2026 13:00 – 14:00", or "19 Apr 2027" for a day.
        let button = Self.find(id: "date-time-button", in: box)
        let words = (button?.string(kAXDescriptionAttribute)).flatMap { $0.isEmpty ? nil : $0 } ?? button?.string(kAXTitleAttribute) ?? ""
        // (Typed into the quick entry it has two spaces before the time: "1 Jan 2028  15:00".)
        let first = (words.components(separatedBy: " – ").first ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for locale in [Locale.current, Locale(identifier: "en_GB")] {
            for (format, day) in [("d MMM yyyy HH:mm", false), ("d MMM yyyy", true)] {
                let f = DateFormatter(); f.locale = locale; f.dateFormat = format
                if let d = f.date(from: first) { return BoxSummary(title: title, start: d, allDay: allDay ?? day) }
            }
        }
        if !words.isEmpty { Log.io("calendar: the box's date wasn't understood (\(words.count) characters)") }
        return BoxSummary(title: title, start: nil, allDay: allDay ?? false)
    }

    /// Done: the title takes the focus and Return saves, as Calendar's own Return in the title does.
    private func saveFromDone() {
        guard let box = eventBox(), let title = Self.find(id: "title-field", in: box) else { return }
        restingDone = false; restingOn = nil; restingFrom = nil
        Tones.press()
        let focus = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute)
        if !(focus.map { $0.isSame(title) } ?? false) {
            boxRebuiltAt = Date()
            _ = title.set(kAXFocusedAttribute, kCFBooleanTrue)
        }
        // From the quick entry the box is built again: the title in the new box takes the focus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            var f = AXUIElementCreateApplication(self.pid).element(kAXFocusedUIElementAttribute)
            if let w = f, w.role == "AXWindow", let again = Self.find(id: "title-field", in: w) {
                _ = again.set(kAXFocusedAttribute, kCFBooleanTrue); f = again
            }
            guard let f, f.string(kAXIdentifierAttribute) == "title-field", let box = self.popover(holding: f) else {
                Log.io("calendar: Done couldn't reach the title"); Tones.edge(); return
            }
            self.saveBox(box) { KeyboardGesture(identifier: "kb:enter")?.send() }
        }
    }

    /// Return in the title or the place saves the event and closes the box: what was saved is said, and the reading
    /// goes to its day in the view, the event chosen (Return opens it). Before, the box closed to "Month, Monday 26
    /// October, no events", nothing said of the event, and finding it took Tab through every event (18 Oct).
    private func saveBox(_ box: AXUIElement, send: () -> Void) {
        let summary = boxSummary(box)
        lastOwnMove = Date()
        send()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.eventBox() == nil else { return }
            self.lastOwnMove = Date()
            var words = String(localized: "Saved: \(summary.title)", comment: "A Calendar event saved: its title")
            if let d = summary.start {
                words += ", " + DateFormatter.localizedString(from: d, dateStyle: .full, timeStyle: .none)
                words += ", " + (summary.allDay ? String(localized: "all day", comment: "A Calendar event lasting all day") : DateFormatter.localizedString(from: d, dateStyle: .none, timeStyle: .short))
            }
            Speech.cancel()
            Speech.speakMessage(words)
            if let d = summary.start { self.goTo(d, title: summary.title) }
        }
    }

    /// The view turned to the day (a page at a time, up to three years), the reading on it and on the event titled so.
    private func goTo(_ date: Date, title: String) {
        let day = Calendar.current.startOfDay(for: date)
        var tries = 0
        let started = Date()
        // A page at a time, for up to five seconds: a date years away (or in Day view) is left for the user.
        while dayShowing(day) == nil, tries < 40, Date().timeIntervalSince(started) < 5 {
            guard let first = days().first?.date, turnPage(forward: day > first) else { break }
            _ = Poll.pumping(every: 0.02, limit: 1.0) { self.days().first?.date != first }
            tries += 1
        }
        guard let shown = dayShowing(day) else { Log.io("calendar: the saved event's day not reached"); return }
        current = shown.date
        eventIndex = title.isEmpty ? nil : events(shown).firstIndex { Self.brief($0).contains(title) }
        lastOwnMove = Date()
        // Calendar's focus put there too, so the view's keys (Up, Down, Return) work at once: after the box it was on
        // the window, and Down did nothing (driver, 18 Oct 2026).
        let target = eventIndex.map { events(shown)[$0] } ?? shown.element
        if target.set(kAXFocusedAttribute, kCFBooleanTrue) != .success { _ = shown.element.set(kAXFocusedAttribute, kCFBooleanTrue) }
        // Calendar posts no focus change for it: TurnOver's own focus follows (said nothing: lastOwnMove).
        AXHandler.shared.focusChanged(target, pid: pid)
        Log.io("calendar: on the saved event's day (\(tries) pages); the event \(eventIndex == nil ? "not found" : "chosen")")
    }

    /// Focus a field of the box. Leaving the quick entry, Calendar builds the box again (the old one gone, the focus on
    /// the window, probe 18 Oct 2026): the same field is found in the new box by its identifier and focused again.
    private func focusField(_ field: AXUIElement, id: String?, retry: Bool) {
        if field.set(kAXFocusedAttribute, kCFBooleanTrue) != .success { Log.io("calendar: the box's field refused the focus") }
        AXHandler.shared.focusChanged(field, pid: pid)
        guard retry, let id else { return }
        boxRebuiltAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let f = AXUIElementCreateApplication(self.pid).element(kAXFocusedUIElementAttribute), f.role == "AXWindow" else { return }
            guard let again = Self.find(id: id, in: f) else { Log.io("calendar: the rebuilt box has no \(id)"); return }
            Log.io("calendar: the box was rebuilt; \(id) focused again")
            self.focusField(again, id: id, retry: false)
        }
    }

    private static func find(id: String, in root: AXUIElement) -> AXUIElement? {
        var queue = [root], seen = 0
        while !queue.isEmpty, seen < 400 {
            let e = queue.removeFirst(); seen += 1
            if e.string(kAXIdentifierAttribute) == id { return e }
            // Not into the month's days and events.
            if !containers.contains(e.string(kAXIdentifierAttribute) ?? "") { queue.append(contentsOf: e.elements(kAXChildrenAttribute)) }
        }
        return nil
    }

    /// The box found from the window, when the focus is on the window itself (the box just built again).
    private func windowsBox() -> AXUIElement? {
        guard let w = AXUIElementCreateApplication(pid).element(kAXFocusedWindowAttribute) else { return nil }
        var queue = [w], seen = 0
        while !queue.isEmpty, seen < 60 {
            let e = queue.removeFirst(); seen += 1
            if e.role == "AXPopover" { return e }
            if !Self.containers.contains(e.string(kAXIdentifierAttribute) ?? "") { queue.append(contentsOf: e.elements(kAXChildrenAttribute)) }
        }
        return nil
    }

    private func pressBoxButton() {
        guard let b = boxButton(), let box = eventBox() else { return }
        let at = boxFields(box).firstIndex { $0.isSame(b) }
        if AXUIElementPerformAction(b, kAXPressAction as CFString) != .success { Log.io("calendar: the box's button didn't press") }
        // A radio button (Event, Reminder) says it's chosen.
        if b.role == "AXRadioButton" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Speech.speakObject(ObjectFactory.make(b), reason: .focus) }; return }
        // The date, alerts, invitees and notes buttons open their part of the box in their place (the date: All Day,
        // the start, the end): Tab is put on the first of it, which is said. A pop-up's menu is read as menus are.
        guard b.role == "AXButton", let at else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let box = self.eventBox() ?? self.windowsBox() else { return }
            let fields = self.boxFields(box)
            // The button still there: nothing opened in its place.
            guard !fields.contains(where: { $0.isSame(b) }), fields.indices.contains(at) else { return }
            let first = fields[at]
            Log.io("calendar: the box's button opened its part")
            if Self.typedRoles.contains(first.role) {
                self.restingOn = nil; self.restingFrom = nil
                self.focusField(first, id: first.string(kAXIdentifierAttribute), retry: false)
            } else {
                self.restingFrom = AXUIElementCreateApplication(self.pid).element(kAXFocusedUIElementAttribute)
                self.restingOn = first
                Speech.cancel()
                Speech.speakObject(ObjectFactory.make(first), reason: .focus)
            }
        }
    }

    override func objectClass(for element: AXUIElement, role: Role, subrole: String?) -> TurnOverObject.Type? {
        let id = element.string(kAXIdentifierAttribute) ?? ""
        if id == "magic-compose-field" { return CalendarQuickEntry.self }
        if CalendarBoxPart.names[id] != nil { return CalendarBoxPart.self }
        return nil
    }

    // MARK: The view

    private func window() -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        return app.element(kAXFocusedWindowAttribute) ?? app.elements(kAXWindowsAttribute).first
    }

    /// The calendar area of the main window (month, week or day), if one is showing.
    private func container() -> AXUIElement? {
        guard let w = window(), let split = w.elements(kAXChildrenAttribute).first(where: { $0.role == "AXSplitGroup" }) else { return nil }
        return split.elements(kAXChildrenAttribute).first { Self.containers.contains($0.string(kAXIdentifierAttribute) ?? "") }
    }

    /// The keyboard is in the calendar area (not the search field, a sheet, the sidebar or an event's details).
    func inView() -> Bool {
        guard let f = API.focusObject, f.pid == pid else { return false }
        var e: AXUIElement? = f.element
        var hops = 0
        while let x = e, hops < 6 {
            let id = x.string(kAXIdentifierAttribute) ?? ""
            if Self.containers.contains(id) || id.hasPrefix("day-column-") { return true }
            if ["AXTextField", "AXTextArea", "AXSheet", "AXPopover"].contains(x.role) { return false }
            e = x.element(kAXParentAttribute); hops += 1
        }
        return false
    }

    struct Day { let element: AXUIElement; let date: Date; let label: String }

    /// The days the view shows, each with its date.
    private func days() -> [Day] {
        guard let c = container() else { return [] }
        let id = c.string(kAXIdentifierAttribute) ?? ""
        let iso = DateFormatter(); iso.locale = Locale(identifier: "en_US_POSIX"); iso.dateFormat = "yyyy-MM-dd"
        if id == "month-container" {
            guard let grid = c.elements(kAXChildrenAttribute).first(where: { $0.role == "AXGrid" }) else { return [] }
            let lists = grid.elements(kAXChildrenAttribute).filter { $0.role == "AXList" }
            let labels = lists.map { $0.string(kAXTitleAttribute) ?? $0.string(kAXDescriptionAttribute) ?? "" }
            guard let month = monthShown(c) else { return [] }
            // Day numbers run up, start again at 1 for the shown month, and again for the next: before the first 1 is
            // the month before. (Labels are the system's language; only the number is read from them.)
            let numbers = labels.map { l in Int(l.components(separatedBy: CharacterSet.decimalDigits.inverted).first { !$0.isEmpty } ?? "") ?? 0 }
            var monthOffset = (numbers.first ?? 1) == 1 ? 0 : -1
            var out: [Day] = []
            for (i, n) in numbers.enumerated() {
                if i > 0, n < numbers[i - 1] { monthOffset += 1 }
                guard let first = Calendar.current.date(byAdding: .month, value: monthOffset, to: month),
                      let date = Calendar.current.date(byAdding: .day, value: max(0, n - 1), to: first) else { continue }
                out.append(Day(element: lists[i], date: date, label: labels[i]))
            }
            return out
        }
        // Week and day: each day's column carries its date in its identifier.
        func columns(_ e: AXUIElement, _ d: Int) -> [AXUIElement] {
            if (e.string(kAXIdentifierAttribute) ?? "").hasPrefix("day-column-") { return [e] }
            return d > 3 ? [] : e.elements(kAXChildrenAttribute).flatMap { columns($0, d + 1) }
        }
        return columns(c, 0).compactMap { e in
            let id = e.string(kAXIdentifierAttribute) ?? ""
            guard let date = iso.date(from: String(id.dropFirst("day-column-".count))) else { return nil }
            return Day(element: e, date: date, label: Self.label(for: date))
        }
    }

    /// "Today, Saturday 17 October", "Wednesday 30 September", in the system's language (week and day views describe
    /// a column by its weekday alone).
    static func label(for date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale.current; f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        let words = f.string(from: date)
        return Calendar.current.isDateInToday(date) ? String(localized: "Today, \(words)", comment: "A Calendar day that is today: %@ is the date") : words
    }

    /// The first day of the month the month view shows ("October 2026" above the grid).
    private func monthShown(_ c: AXUIElement) -> Date? {
        guard let title = c.elements(kAXChildrenAttribute).first(where: { $0.string(kAXIdentifierAttribute) == "view-date-title" })?.string(kAXValueAttribute) else { return nil }
        for locale in [Locale.current, Locale(identifier: "en_GB")] {
            let f = DateFormatter(); f.locale = locale; f.dateFormat = "MMMM yyyy"
            if let d = f.date(from: title) { return d }
        }
        return nil
    }

    private func events(_ day: Day) -> [AXUIElement] {
        // Static texts (17 Oct 2026); buttons on 18 Oct ("Holiday. 1 May 2030, All-Day, button"): either.
        day.element.elements(kAXChildrenAttribute).filter { ["AXStaticText", "AXButton"].contains($0.role) && !($0.string(kAXDescriptionAttribute) ?? "").isEmpty }
    }

    // MARK: Moving

    /// Where reading starts when TurnOver's day isn't in view: the day Calendar has focused, else today, else the first.
    private func startingDay() -> Day? {
        let all = days()
        return all.first { ($0.element.attr(kAXFocusedAttribute) as? Bool) == true } ?? all.first { Calendar.current.isDateInToday($0.date) } ?? all.first
    }

    private func dayShowing(_ date: Date) -> Day? {
        let d = Calendar.current.startOfDay(for: date)
        return days().first { Calendar.current.isDate($0.date, inSameDayAs: d) }
    }

    /// The view's own previous or next button (previous month, next week, …).
    /// Focus events inside the calendar area just after TurnOver's own move are Calendar following it: not read.
    /// Back from an opened event (Escape), the event is said again in a few words instead of the whole area.
    override func handleEvent(_ event: Event, next: () -> Void) {
        // Typing while Tab rests on a button or Done goes into the field that has the focus: the rest is over, so
        // Return is the field's again (a code review on 18 Oct 2026).
        if event.kind == .typedCharacter, restingOn != nil || restingDone { restingOn = nil; restingDone = false; restingFrom = nil }
        // The box being built again after the quick entry (focusField): the window's moment of focus isn't said.
        if event.kind == .gainFocus, event.obj.pid == pid, event.obj.element.role == "AXWindow", Date().timeIntervalSince(boxRebuiltAt) < 1.0 { return }
        // An opened event: Calendar says its title field, then puts the focus on the box itself, where typing and the
        // arrows did nothing (18 Oct 2026: checking a title's spelling). The title keeps the focus.
        // Once per box: a box Calendar puts the focus on again later (a part opened in it) keeps it where it goes.
        if event.kind == .gainFocus, event.obj.pid == pid, event.obj.element.role == "AXPopover",
           !(titledBox.map { $0.isSame(event.obj.element) } ?? false),
           Self.find(id: "magic-compose-field", in: event.obj.element) == nil,   // a new event's box: the quick entry has it
           let title = Self.find(id: "title-field", in: event.obj.element) {
            titledBox = event.obj.element
            Log.io("calendar: the box took the focus; given to its title")
            _ = title.set(kAXFocusedAttribute, kCFBooleanTrue)
            AXHandler.shared.focusChanged(title, pid: pid)
            return
        }
        if [.gainFocus, .focusEntered].contains(event.kind), event.obj.pid == pid, inArea(event.obj.element) {
            if opened == .showing {
                opened = .no
                lastOwnMove = Date()
                DispatchQueue.main.async { [weak self] in self?.sayEvent() }
                return
            }
            if Date().timeIntervalSince(lastOwnMove) < 1.0 { return }
            // Arriving in the area (Command-1, 2 or 3, Tab from the sidebar, the app coming forward): the view and the
            // day in a line ("Week, Wednesday 30 September, 1 event") instead of "Week Calendar Area, grouping,
            // September 2026, group, Wednesday, list" and an event's whole sentence (17 Oct 2026).
            let id = event.obj.element.string(kAXIdentifierAttribute) ?? ""
            if event.kind == .focusEntered { return }
            if Self.containers.contains(id) || id.hasPrefix("day-column-") {
                lastOwnMove = Date()
                if let start = startingDay() { current = start.date; eventIndex = nil }
                let view = (container()?.string(kAXIdentifierAttribute) ?? "").replacingOccurrences(of: "-container", with: "")
                DispatchQueue.main.async { [weak self] in self?.sayDay(prefix: view.isEmpty ? "" : view.prefix(1).uppercased() + view.dropFirst() + ", ") }
                return
            }
        }
        if opened == .waiting, [.gainFocus, .focusEntered].contains(event.kind), inPopover(event.obj.element) { opened = .showing }
        next()
    }

    private func inArea(_ element: AXUIElement) -> Bool {
        var e: AXUIElement? = element
        var hops = 0
        while let x = e, hops < 8 {
            let id = x.string(kAXIdentifierAttribute) ?? ""
            if Self.containers.contains(id) || id.hasPrefix("day-column-") { return true }
            e = x.element(kAXParentAttribute); hops += 1
        }
        return false
    }
    private func inPopover(_ element: AXUIElement) -> Bool {
        var e: AXUIElement? = element
        var hops = 0
        while let x = e, hops < 10 { if x.role == "AXPopover" || x.role == "AXSheet" { return true }; e = x.element(kAXParentAttribute); hops += 1 }
        return false
    }

    private func turnPage(forward: Bool) -> Bool {
        lastOwnMove = Date()
        guard let c = container() else { return false }
        let wanted = forward ? "next" : "previous"
        guard let b = c.elements(kAXChildrenAttribute).first(where: { $0.role == "AXButton" && ($0.string(kAXIdentifierAttribute) ?? "").hasPrefix(wanted) }) else { return false }
        return AXUIElementPerformAction(b, kAXPressAction as CFString) == .success
    }

    private func moveDays(_ n: Int, _ g: KeyboardGesture) {
        // The reading starts where the view is: today if it shows today, else its first day.
        if dayShowing(current) == nil, let start = startingDay() { current = start.date }
        guard let target = Calendar.current.date(byAdding: .day, value: n, to: current) else { return }
        var tries = 0
        while dayShowing(target) == nil, tries < 3 {
            guard turnPage(forward: n > 0) else { break }
            _ = Poll.pumping(every: 0.02, limit: 1.0) { self.dayShowing(target) != nil }
            tries += 1
        }
        guard dayShowing(target) != nil else { Tones.edge(); Log.io("calendar: \(target) not reached"); return }
        current = target; eventIndex = nil
        lastOwnMove = Date()
        sayDay()
    }

    private func sayDay(prefix: String = "") {
        guard let day = dayShowing(current) else { return }
        let n = events(day).count
        let label = day.label.isEmpty ? DateFormatter.localizedString(from: day.date, dateStyle: .full, timeStyle: .none) : day.label
        Speech.cancel()
        Speech.speakMessage("\(prefix)\(label), \(n == 0 ? String(localized: "no events", comment: "Spoken message") : n == 1 ? String(localized: "1 event", comment: "A day's events") : String(localized: "\(String(n)) events", comment: "A day's events"))")
    }

    private func moveEvent(_ step: Int, _ g: KeyboardGesture) {
        if dayShowing(current) == nil, let start = startingDay() { current = start.date; eventIndex = nil }
        guard let day = dayShowing(current) else { g.send(); return }
        let list = events(day)
        guard !list.isEmpty else { Tones.edge(); Speech.speakMessage(String(localized: "no events", comment: "Spoken message")); return }
        let next: Int
        if let i = eventIndex { next = i + step } else { next = step > 0 ? 0 : -1 }
        if next < 0 { eventIndex = nil; Tones.edge(); sayDay(); return }   // above the first: the day again
        guard next < list.count else { Tones.edge(); return }
        eventIndex = next
        sayEvent()
    }

    private func sayEvent() {
        guard let day = dayShowing(current), let i = eventIndex else { return }
        let list = events(day)
        guard i < list.count else { return }
        Speech.cancel()
        Speech.speakMessage("\(Self.brief(list[i])), \(Phrases.position(i + 1, of: list.count))")
    }

    private func openEvent(_ g: KeyboardGesture) {
        guard let day = dayShowing(current), let i = eventIndex, i < events(day).count else { g.send(); return }
        let e = events(day)[i]
        Tones.press()
        opened = .waiting
        lastOwnMove = Date()
        _ = AXUIElementPerformAction(e, kAXPressAction as CFString)
    }

    // MARK: Words

    /// An event in a few words, the time first: "14:00 to 15:00, Team meeting, Room 2"; "all day, Holiday".
    /// Calendar's own sentence when it isn't one of the two shapes it uses (another language, a multi-day event).
    static func brief(_ e: AXUIElement) -> String {
        let d = (e.string(kAXDescriptionAttribute) ?? "").trimmingCharacters(in: .whitespaces)
        let ns = d as NSString
        if let re = try? NSRegularExpression(pattern: #"^(.*)\. Starts on .+? at (\d{1,2}[:.]\d{2}) and ends at (\d{1,2}[:.]\d{2})\.?$"#),
           let m = re.firstMatch(in: d, range: NSRange(location: 0, length: ns.length)) {
            return "\(ns.substring(with: m.range(at: 2))) to \(ns.substring(with: m.range(at: 3))), \(ns.substring(with: m.range(at: 1)))"
        }
        if let re = try? NSRegularExpression(pattern: #"^(.*)\. [^.]+, All-Day\.?$"#), let m = re.firstMatch(in: d, range: NSRange(location: 0, length: ns.length)) {
            return "all day, \(ns.substring(with: m.range(at: 1)))"
        }
        return d
    }
}

/// The box's unnamed parts, named by their identifiers ("pop up button, None" was the video call; the start and end
/// each said "2 Nov 2026 at 13:00" twice, a date picker and a time picker): "Video call, None", "Starts, date,
/// 2 November 2026", "Starts, time, 13:00", "Repeat, Never".
final class CalendarBoxPart: TurnOverObject {
    static var names: [String: String] { [
        "virtualconference-button": String(localized: "Video call", comment: "A field of a Calendar event"), "calendar-button": String(localized: "Calendar", comment: "A field of a Calendar event"),
        "recurrence-button": String(localized: "Repeat", comment: "A field of a Calendar event"), "traveltime-button": String(localized: "Travel time", comment: "A field of a Calendar event"),
        "allday-checkbox": String(localized: "All day", comment: "A field of a Calendar event"),
        "start-datepicker": String(localized: "Starts, date", comment: "A field of a Calendar event"), "start-timepicker": String(localized: "Starts, time", comment: "A field of a Calendar event"),
        "end-datepicker": String(localized: "Ends, date", comment: "A field of a Calendar event"), "end-timepicker": String(localized: "Ends, time", comment: "A field of a Calendar event"),
    ] }
    private var id: String { element.string(kAXIdentifierAttribute) ?? "" }
    override var name: String {
        let own = super.name
        return own.isEmpty ? Self.names[id] ?? own : own
    }
    override var value: String? {
        guard id.hasSuffix("picker"), let date = element.attr(kAXValueAttribute) as? Date else { return super.value }
        let f = DateFormatter()
        if id.hasSuffix("datepicker") { f.dateStyle = .long; f.timeStyle = .none } else { f.dateStyle = .none; f.timeStyle = .short }
        return f.string(from: date)
    }
}

/// The new event box's first field: Calendar's quick entry, with no label of its own ("edit, blank").
final class CalendarQuickEntry: EditableText {
    override var name: String {
        let own = super.name
        return own.isEmpty ? String(localized: "Quick entry: describe the event, like Lunch with a friend Friday at 1, then Return", comment: "Calendar's quick entry field") : own
    }
}

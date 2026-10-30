// SPDX-License-Identifier: GPL-3.0-or-later
// Maps (18 Oct 2026, the Apple apps sweep). Maps is the iPad app: a sidebar, the map (an AXMapArea of places, each a
// map item), and a card beside it with the search field, results, a place's details and directions (probe). Command
// F and a search worked; after Return the results were unread: the arrows said nothing and Tab found only buttons
// (driver). TurnOver reads the window's content as a document, as it does Books and Kindle's screens: Down through
// the results, a place's details or a route's steps, H between sections, Return on a result to open it. The map's
// dots are left out of that reading (Maps' own list of results says the same places in order).
import Foundation
import ApplicationServices

final class MapsAppModule: AppModule {
    static let bundleID = "com.apple.Maps"
    static let contentSubrole = "iOSContentGroup"

    required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        WebBuffer.iosSkippedSubroles.insert("AXMapArea")
        // Command F: Maps puts the keyboard in its search field at once; TurnOver goes to typing with it, or the first
        // letters were taken as quick navigation keys ("c" a check box, "f" a field: driver, 18 Oct 2026).
        script("maps_search", String(localized: "Search Maps; typing goes into the search field", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:command+f"], category: "Maps") { [weak self] g in
            g.send()
            guard let self, let doc = API.focusTreeInterceptor, doc.webArea.pid == self.pid else { return }
            doc.setPassThrough(true, announce: false)
            Speech.speakMessage(String(localized: "search", comment: "Spoken message"))
        }
    }

    override func browseRoot(for element: AXUIElement, ancestors: [TurnOverObject]) -> AXUIElement? {
        // Not while typing in the search field: that stays a field.
        if element.string(kAXSubroleAttribute) == "AXSearchField" { return nil }
        if element.string(kAXSubroleAttribute) == Self.contentSubrole { return element }
        return ancestors.first { $0.element.string(kAXSubroleAttribute) == Self.contentSubrole }?.element
    }
}

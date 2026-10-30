// SPDX-License-Identifier: GPL-3.0-or-later
// Apple Books (18 Oct 2026, the Apple apps sweep). Books is the iPad app: its window holds a sidebar (Home, Book
// Store, Library, collections) and shelves, each a heading, a header button ("Special Offers & Free") and a row of
// books, each book a button described with a book's title and author (probe). Tab went from shelf header to an unnamed
// arrow button at the shelf's edge ("button") and on, never to a book; the arrows did nothing TurnOver heard (driver).
// What TurnOver changes:
// - The window's content is read as a document (as Kindle's own screens are): Down through the sidebar, the shelves
//   and every book on them, H from shelf to shelf, Return to open a book or press a button.
// - The unnamed arrow buttons at a shelf's ends are "previous" and "next".
import Foundation
import ApplicationServices

final class BooksAppModule: AppModule {
    static let bundleID = "com.apple.iBooksX"
    static let contentSubrole = "iOSContentGroup"

    override func browseRoot(for element: AXUIElement, ancestors: [TurnOverObject]) -> AXUIElement? {
        if element.string(kAXSubroleAttribute) == Self.contentSubrole { return element }
        return ancestors.first { $0.element.string(kAXSubroleAttribute) == Self.contentSubrole }?.element
    }

    override func objectClass(for element: AXUIElement, role: Role, subrole: String?) -> TurnOverObject.Type? {
        role == .button ? BooksButton.self : nil
    }
}

/// A button in Books: the shelves' unnamed arrows named by which end of their shelf they sit at.
final class BooksButton: TurnOverObject {
    override var name: String {
        let own = super.name
        guard own.isEmpty, let mine = TurnOverObject.frame(element),
              let shelf = element.element(kAXParentAttribute).flatMap({ TurnOverObject.frame($0) }), shelf.width > mine.width * 3 else { return own }
        return mine.midX > shelf.midX ? "next" : "previous"
    }
}

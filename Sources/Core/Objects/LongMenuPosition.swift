// SPDX-License-Identifier: GPL-3.0-or-later
import ApplicationServices
import Foundation
import TurnOverAX

/// A menu item's place in a menu of over 200 items (TurnOver's own Voice menu has 307 voices). AppKit answers AXIndex
/// 0 for every menu item, so reading AXIndex said "1 of 307" on every voice (25 Nov 2026). The menu's titled items are
/// read in one pass instead, and kept while the same menu stays open with the same number of items.
///
/// The cost, for one item in a menu of 307 (counted from the code, 25 Nov 2026; the three questions before it, the
/// item's parent, the parent's role and its child count, are asked for every listed item whatever its menu):
/// - the first item focused: the item's title (1), the menu's children (1), and role and title together for each
///   child (307): 309 questions;
/// - every item after it, while the list is kept: the item's title (1), and it is found in the kept list: 1 question;
/// - an item not found in the kept list (the menu was opened again, or the app gives a new element each time):
///   the same 309 as the first time, once; never a second read for one focus;
/// - an item without a title: its title (1) and nothing else; such an item gets no position, as in a short menu.
/// An app that stops answering: AXHealth leaves it alone after one question times out, so the rest fail at once,
/// and a read with any unanswered child is not kept and gives no position, rather than a position counted from part
/// of the menu.
public enum LongMenuPosition {
    public struct Entry { public let element: AXUIElement; public let title: String }

    // Main actor only (the reader's state; TurnOverCore's default isolation).
    private static var kept: (menu: AXUIElement, count: Int, at: Date, items: [Entry])?
    nonisolated static let keepFor: TimeInterval = 60

    /// Where `element` (a menu item) is among `menu`'s titled items: its 1-based index and their count.
    static func position(of element: AXUIElement, in menu: AXUIElement, childCount: Int) -> (index: Int, count: Int)? {
        guard let title = element.string(kAXTitleAttribute), !title.isEmpty else { return nil }
        var keptItems: [Entry]?
        if let k = kept, keptIsUsable(sameMenu: CFEqual(k.menu, menu), keptCount: k.count, count: childCount, age: Date().timeIntervalSince(k.at)) {
            keptItems = k.items
        }
        var ownFrame: CGRect??
        let found = find(kept: keptItems, read: { read(menu, childCount: childCount) },
                         exact: { $0.firstIndex(where: { CFEqual($0.element, element) }) },
                         loose: { list in
                             pick(list, title: title, titleOf: { $0.title }, sameFrame: { e in
                                 if ownFrame == nil { ownFrame = TurnOverObject.frame(element) }
                                 guard let f = ownFrame ?? nil, let g = TurnOverObject.frame(e.element) else { return false }
                                 return abs(g.minX - f.minX) < 1 && abs(g.minY - f.minY) < 1
                             })
                         })
        return found.map { ($0.index + 1, $0.items.count) }
    }

    /// The menu's children, each asked its role and title in one question; the titled menu items kept.
    private static func read(_ menu: AXUIElement, childCount: Int) -> [Entry]? {
        // Each read is logged with its size and time (review of #388, 27 Nov 2026): a long menu that feels slow in
        // some app shows here.
        let started = Date()
        guard childCount <= 5000, let kids = menu.attr(kAXChildrenAttribute) as? [AXUIElement] else {
            Log.io("long menu: \(childCount) children, not read (\(ms(since: started)) ms)"); return nil
        }
        var described: [(element: AXUIElement, role: String?, title: String?)] = []
        described.reserveCapacity(kids.count)
        for kid in kids {
            let d = kid.attrs([kAXRoleAttribute, kAXTitleAttribute])
            if d.isEmpty {   // no answer: never a position from part of the menu
                kept = nil
                Log.io("long menu: child \(described.count + 1) of \(kids.count) did not answer after \(ms(since: started)) ms; no position")
                return nil
            }
            described.append((kid, d[kAXRoleAttribute] as? String, d[kAXTitleAttribute] as? String))
        }
        let items = titledItems(described).map { Entry(element: $0.0, title: $0.1) }
        kept = (menu, childCount, Date(), items)
        Log.io("long menu: read \(kids.count) children, \(items.count) titled items, in \(ms(since: started)) ms")
        return items
    }

    private static func ms(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

    // MARK: - The choices, without the app (tested with plain lists)

    /// The children that count: menu items with a title. A menu's separators are untitled menu items.
    public nonisolated static func titledItems<E>(_ kids: [(element: E, role: String?, title: String?)]) -> [(E, String)] {
        kids.compactMap { k in
            guard k.role == "AXMenuItem", let t = k.title, !t.isEmpty else { return nil }
            return (k.element, t)
        }
    }

    /// The kept list is for the same menu, with the same number of children, read within the last minute.
    public nonisolated static func keptIsUsable(sameMenu: Bool, keptCount: Int, count: Int, age: TimeInterval) -> Bool {
        sameMenu && keptCount == count && age >= 0 && age < keepFor
    }

    /// The kept list is tried first, by the element itself only. Not there, the menu is read once, and the element
    /// is looked for again, then by title and place. At most one read for one focus.
    public nonisolated static func find<E>(kept: [E]?, read: () -> [E]?, exact: ([E]) -> Int?, loose: ([E]) -> Int?) -> (index: Int, items: [E])? {
        if let kept, let i = exact(kept) { return (i, kept) }
        guard let fresh = read() else { return nil }
        if let i = exact(fresh) ?? loose(fresh) { return (i, fresh) }
        return nil
    }

    /// An item that does not compare equal (an app that makes a new element each time it's asked): the one item with
    /// its title, or, where several share it, the one in the same place, as a short menu does (issue 140). The
    /// place is asked only of the items with that title.
    public nonisolated static func pick<E>(_ list: [E], title: String, titleOf: (E) -> String, sameFrame: (E) -> Bool) -> Int? {
        let named = list.indices.filter { titleOf(list[$0]) == title }
        if named.count == 1 { return named[0] }
        return named.first(where: { sameFrame(list[$0]) })
    }
}

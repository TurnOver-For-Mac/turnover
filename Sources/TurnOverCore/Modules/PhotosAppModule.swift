// SPDX-License-Identifier: GPL-3.0-or-later
// Photos (18 Oct 2026, the Apple apps sweep). The library is a grid (an AXCollectionList, "photos_collection_view",
// of sections, each with a heading and its photos and videos as images) beside a sidebar outline. The arrows moved
// through the grid in silence (driver); the sidebar said "level 2" on its inner rows.
// What TurnOver changes:
// - Each arrow in the grid reads the photo or video now chosen (Photos' own description of it), read without
//   holding the key up, as Freeform's boards are.
// - The sidebar's rows without their level.
import Foundation
import ApplicationServices
import AppKit

final class PhotosAppModule: AppModule {
    static let bundleID = "com.apple.Photos"

    required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        for key in ["leftArrow", "rightArrow", "upArrow", "downArrow"] {
            script("photos_\(key)", String(localized: "The next photo that way, read", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:\(key)"], category: "Photos") { [weak self] g in
                guard let self, let grid = self.grid() else { g.send(); return }
                let before = self.chosen(in: grid)
                g.send()
                func look(_ tries: Int) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        if let now = self.chosen(in: grid), !(before.map { $0.isSame(now) } ?? false) {
                            Speech.cancel(); Speech.speakObject(ObjectFactory.make(now), reason: .focus)
                        } else if tries > 1 { look(tries - 1) } else { Tones.edge() }
                    }
                }
                look(5)
            }.isAvailable = { [weak self] in self?.grid() != nil }
        }
    }

    /// The photo grid, when the keyboard is on it or in it.
    private func grid() -> AXUIElement? {
        // Photos' own focus: a photo in the grid is a nameless group, and TurnOver sets such a focus aside.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let f = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute) else { return nil }
        var e: AXUIElement? = f; var hops = 0
        while let x = e, hops < 6 {
            if x.string(kAXSubroleAttribute) == "AXCollectionList" { return x }
            // The library's scroll group holds the grid.
            if x.string(kAXIdentifierAttribute) == "LibraryScrollView" {
                return x.elements(kAXChildrenAttribute).first { $0.string(kAXSubroleAttribute) == "AXCollectionList" }
            }
            e = x.element(kAXParentAttribute); hops += 1
        }
        return nil
    }

    /// The photo or video chosen: the selected one, else the one with the focus. Only the sections on screen are
    /// looked through.
    private func chosen(in grid: AXUIElement) -> AXUIElement? {
        var focused: AXUIElement?
        // Photos' own focused element first: it is the chosen photo when Photos says so.
        if let f = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute), f.string(kAXIdentifierAttribute) == "mediaKind_asset" { return f }
        for section in grid.elements(kAXChildrenAttribute).prefix(400) {
            for item in section.elements(kAXChildrenAttribute) where item.role == "AXImage" || item.string(kAXIdentifierAttribute) == "mediaKind_asset" {
                if (item.attr(kAXSelectedAttribute) as? Bool) == true { return item }
                if focused == nil, (item.attr(kAXFocusedAttribute) as? Bool) == true { focused = item }
            }
        }
        return focused
    }

    override func objectClass(for element: AXUIElement, role: Role, subrole: String?) -> TurnOverObject.Type? {
        [.treeViewItem, .tableRow].contains(role) ? RowWithoutLevel.self : nil
    }
}

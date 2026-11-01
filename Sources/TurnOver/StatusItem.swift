// SPDX-License-Identifier: GPL-3.0-or-later
// The Mac-side presence: a "TurnOver" item in the menu bar while TurnOver runs, and the
// login item (SMAppService). Both follow the General preferences. Opening TurnOver
// from Applications while it is running speaks a word and opens the TurnOver menu.
import AppKit
import ServiceManagement
import TurnOverCore

final class StatusItem: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private var keyObserver: NSObjectProtocol?

    func apply() {
        applyLoginItem()
        if config.general.showInMenuBar { show() } else { hide() }
    }

    private func show() {
        guard item == nil else { return }
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        it.button?.title = "TurnOver"
        it.button?.setAccessibilityLabel("TurnOver")
        let menu = NSMenu(title: "TurnOver")
        menu.addItem(withTitle: "TurnOver menu: Command Control Comma, from anywhere", action: #selector(openMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Every shortcut: the TurnOver menu, Keys", action: #selector(openShortcuts), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = config.general.openAtLogin ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit TurnOver", action: #selector(quit), keyEquivalent: "").target = self
        menu.delegate = self
        it.menu = menu
        item = it
        // TurnOver cannot read its own item through accessibility (asking itself would block its own main thread), so the
        // item speaks for itself: when the status menus (Control-F8, VO-M three times) reach it, and in its menu.
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: it.button?.window, queue: .main) { _ in
            MainActor.assumeIsolated { Speech.cancel(); Speech.speakMessage(String(localized: "TurnOver, menu extra", comment: "Spoken message")) }
        }
    }

    func menuWillOpen(_ menu: NSMenu) { Speech.cancel(); Speech.speakMessage(String(localized: "TurnOver menu", comment: "Spoken message")) }
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard let item, !item.isSeparatorItem else { return }
        Speech.cancel()
        Speech.speakMessage(item.state == .on ? "\(item.title), \(State.checked.displayString)" : item.title)
    }

    private func hide() {
        if let o = keyObserver { NotificationCenter.default.removeObserver(o); keyObserver = nil }
        if let it = item { NSStatusBar.system.removeStatusItem(it) }
        item = nil
    }

    private func applyLoginItem() {
        let service = SMAppService.mainApp
        let want = config.general.openAtLogin
        let have = service.status == .enabled
        guard want != have else { return }
        do {
            if want { try service.register() } else { try service.unregister() }
            Log.info("login item \(want ? "registered" : "unregistered")")
        } catch {
            Log.error("login item: \(error)")
            Speech.speakMessage(String(localized: "could not change open at login: \(error.localizedDescription)", comment: "Open at login failed: %@ is why"))
        }
        item?.menu?.items.first { $0.action == #selector(toggleLogin) }?.state = config.general.openAtLogin ? .on : .off
    }

    @objc private func openMenu() { MenuAnywhere.shared.open() }   // where VoiceOver leads too ()
    @objc private func openShortcuts() { GlobalCommands.openShortcutsList() }
    @objc private func toggleLogin() {
        config.general.openAtLogin.toggle(); config.save()
        applyLoginItem()
        Speech.speakMessage(String(localized: "open at login \(Phrases.onOff(config.general.openAtLogin))", comment: "Open at login changed: %@ is on or off"))
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

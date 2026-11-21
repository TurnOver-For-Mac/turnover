// SPDX-License-Identifier: GPL-3.0-or-later
// Mail's Save Attachments panel (17 Nov 2026): Mail's own keys stay out of sheets, dialogs and the Open and Save panel.
// Logic evidence only: the decision from the focus's ancestors, not Mail's real tree, which only a live check shows.
import Foundation
import TurnOverCore

func mailPanelTests() {
    test("Mail: the Open and Save panel's file list is not Mail's mailbox list") {
        let service = MailAppModule.panelServiceBundle
        // The panel's outline as it arrived through Mail's observer: its application ancestor is the panel service.
        check(MailAppModule.isOutsideMailsOwnContent(ancestorRoles: [.scrollPane, .window, .application], ownerBundle: service),
              "an outline drawn by the panel service")
        // The same outline, its ancestors running through Mail's sheet.
        check(MailAppModule.isOutsideMailsOwnContent(ancestorRoles: [.scrollPane, .sheet, .window, .application], ownerBundle: "com.apple.mail"),
              "anything inside a sheet")
        check(MailAppModule.isOutsideMailsOwnContent(ancestorRoles: [.groupBox, .dialog, .application], ownerBundle: "com.apple.mail"),
              "a dialog of Mail's own (its Tab is the dialog's)")
        check(!MailAppModule.isOutsideMailsOwnContent(ancestorRoles: [.scrollPane, .splitPane, .window, .application], ownerBundle: "com.apple.mail"),
              "Mail's mailbox list in its viewer window keeps Mail's keys")
        check(!MailAppModule.isOutsideMailsOwnContent(ancestorRoles: [.groupBox, .scrollPane, .window, .application], ownerBundle: "com.apple.WebKit.WebContent"),
              "a message body drawn by WebKit is Mail's own content")
        check(!MailAppModule.isOutsideMailsOwnContent(ancestorRoles: [], ownerBundle: nil), "no ancestors known: Mail's keys as before")
    }
}

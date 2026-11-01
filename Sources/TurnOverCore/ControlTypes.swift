// SPDX-License-Identifier: GPL-3.0-or-later
// Roles and states (NVDA: controlTypes), with the words they are spoken as and
// the mapping from the macOS accessibility roles that AppKit, Office and
// WebKit report.
import Foundation
import ApplicationServices

public enum Role: String, Codable, CaseIterable {
    case unknown, window, dialog, sheet, drawer, application, pane, groupBox, splitPane, separator
    case toolBar, scrollPane, scrollBar, statusBar, menuBar, menu, menuItem, checkMenuItem, radioMenuItem, popupMenu
    case button, menuButton, toggleButton, switchControl, checkBox, radioButton, link, comboBox, dropDownList, popUpButton, spinButton, slider
    case editableText, document, searchField, passwordEdit, staticText, heading, label, placeholder
    case list, listItem, table, tableRow, tableColumn, tableCell, tableHeader, treeView, treeViewItem, treeViewButton, outline, browser
    case tabControl, tab, progressBar, busyIndicator, levelIndicator, colorChooser, image, graphic, dateEditor, timeEditor
    case toolTip, layoutArea, layoutItem, handle, grid, cell, matte, ruler, valueIndicator, incrementor, disclosureTriangle, dockItem, webArea
    case textFrame, section, landmark, embeddedObject, math, terminal, page

    /// Containers and plain content: "unavailable" is not said of them even when the app reports them disabled.
    public static let neverUnavailable: Set<Role> = [.list, .groupBox, .unknown, .page, .scrollPane, .splitPane, .staticText, .graphic,
        .image, .layoutArea, .toolBar, .table, .tableCell, .cell, .tableRow, .treeView, .outline, .tabControl, .window, .webArea, .document, .pane, .section, .landmark]

    /// What the role is called (NVDA: Role.displayString).
    nonisolated public var displayString: String {
        switch self {
        case .unknown: return String(localized: "unknown", comment: "A role, spoken after an item's name")
        case .window: return String(localized: "window", comment: "A role, spoken after an item's name")
        case .dialog: return String(localized: "dialog", comment: "A role, spoken after an item's name")
        case .sheet: return String(localized: "sheet", comment: "A role, spoken after an item's name")
        case .drawer: return String(localized: "drawer", comment: "A role, spoken after an item's name")
        case .application: return String(localized: "application", comment: "A role, spoken after an item's name")
        case .pane: return String(localized: "pane", comment: "A role, spoken after an item's name")
        case .groupBox: return String(localized: "grouping", comment: "A role, spoken after an item's name")
        case .splitPane: return String(localized: "split pane", comment: "A role, spoken after an item's name")
        case .separator: return String(localized: "separator", comment: "A role, spoken after an item's name")
        case .toolBar: return String(localized: "tool bar", comment: "A role, spoken after an item's name")
        case .scrollPane: return String(localized: "scroll pane", comment: "A role, spoken after an item's name")
        case .scrollBar: return String(localized: "scroll bar", comment: "A role, spoken after an item's name")
        case .statusBar: return String(localized: "status bar", comment: "A role, spoken after an item's name")
        case .menuBar: return String(localized: "menu bar", comment: "A role, spoken after an item's name")
        case .menu: return String(localized: "menu", comment: "A role, spoken after an item's name")
        case .menuItem: return String(localized: "menu item", comment: "A role, spoken after an item's name")
        case .checkMenuItem: return String(localized: "check menu item", comment: "A role, spoken after an item's name")
        case .radioMenuItem: return String(localized: "radio menu item", comment: "A role, spoken after an item's name")
        case .popupMenu: return String(localized: "popup menu", comment: "A role, spoken after an item's name")
        case .button: return String(localized: "button", comment: "A role, spoken after an item's name")
        case .menuButton: return String(localized: "menu button", comment: "A role, spoken after an item's name")
        case .toggleButton: return String(localized: "toggle button", comment: "A role, spoken after an item's name")
        case .switchControl: return String(localized: "switch", comment: "A role, spoken after an item's name")
        case .checkBox: return String(localized: "check box", comment: "A role, spoken after an item's name")
        case .radioButton: return String(localized: "radio button", comment: "A role, spoken after an item's name")
        case .link: return String(localized: "link", comment: "A role, spoken after an item's name")
        case .comboBox: return String(localized: "combo box", comment: "A role, spoken after an item's name")
        case .dropDownList: return String(localized: "drop down list", comment: "A role, spoken after an item's name")
        case .popUpButton: return String(localized: "pop up button", comment: "A role, spoken after an item's name")
        case .spinButton: return String(localized: "spin button", comment: "A role, spoken after an item's name")
        case .slider: return String(localized: "slider", comment: "A role, spoken after an item's name")
        case .editableText: return String(localized: "edit", comment: "A role, spoken after an item's name")
        case .document: return String(localized: "document", comment: "A role, spoken after an item's name")
        case .searchField: return String(localized: "search", comment: "A role, spoken after an item's name")
        case .passwordEdit: return String(localized: "password edit", comment: "A role, spoken after an item's name")
        case .staticText: return String(localized: "text", comment: "A role, spoken after an item's name")
        case .heading: return String(localized: "heading", comment: "A role, spoken after an item's name")
        case .label: return String(localized: "label", comment: "A role, spoken after an item's name")
        case .placeholder: return String(localized: "placeholder", comment: "A role, spoken after an item's name")
        case .list: return String(localized: "list", comment: "A role, spoken after an item's name")
        case .listItem: return String(localized: "list item", comment: "A role, spoken after an item's name")
        case .table: return String(localized: "table", comment: "A role, spoken after an item's name")
        case .tableRow: return String(localized: "row", comment: "A role, spoken after an item's name")
        case .tableColumn: return String(localized: "column", comment: "A role, spoken after an item's name")
        case .tableCell: return String(localized: "cell", comment: "A role, spoken after an item's name")
        case .tableHeader: return String(localized: "header", comment: "A role, spoken after an item's name")
        case .treeView: return String(localized: "tree view", comment: "A role, spoken after an item's name")
        case .treeViewItem: return String(localized: "tree view item", comment: "A role, spoken after an item's name")
        case .treeViewButton: return String(localized: "tree view button", comment: "A role, spoken after an item's name")
        case .outline: return String(localized: "tree view", comment: "A role, spoken after an item's name")
        case .browser: return String(localized: "browser", comment: "A role, spoken after an item's name")
        case .tabControl: return String(localized: "tab control", comment: "A role, spoken after an item's name")
        case .tab: return String(localized: "tab", comment: "A role, spoken after an item's name")
        case .progressBar: return String(localized: "progress bar", comment: "A role, spoken after an item's name")
        case .busyIndicator: return String(localized: "busy indicator", comment: "A role, spoken after an item's name")
        case .levelIndicator: return String(localized: "level indicator", comment: "A role, spoken after an item's name")
        case .colorChooser: return String(localized: "color chooser", comment: "A role, spoken after an item's name")
        case .image: return String(localized: "image", comment: "A role, spoken after an item's name")
        case .graphic: return String(localized: "graphic", comment: "A role, spoken after an item's name")
        case .dateEditor: return String(localized: "date editor", comment: "A role, spoken after an item's name")
        case .timeEditor: return String(localized: "time editor", comment: "A role, spoken after an item's name")
        case .toolTip: return String(localized: "tool tip", comment: "A role, spoken after an item's name")
        case .layoutArea: return String(localized: "layout area", comment: "A role, spoken after an item's name")
        case .layoutItem: return String(localized: "layout item", comment: "A role, spoken after an item's name")
        case .handle: return String(localized: "handle", comment: "A role, spoken after an item's name")
        case .grid: return String(localized: "grid", comment: "A role, spoken after an item's name")
        case .cell: return String(localized: "cell", comment: "A role, spoken after an item's name")
        case .matte: return String(localized: "matte", comment: "A role, spoken after an item's name")
        case .ruler: return String(localized: "ruler", comment: "A role, spoken after an item's name")
        case .valueIndicator: return String(localized: "value indicator", comment: "A role, spoken after an item's name")
        case .incrementor: return String(localized: "stepper", comment: "A role, spoken after an item's name")
        case .disclosureTriangle: return String(localized: "disclosure triangle", comment: "A role, spoken after an item's name")
        case .dockItem: return String(localized: "dock item", comment: "A role, spoken after an item's name")
        case .webArea: return String(localized: "document", comment: "A role, spoken after an item's name")
        case .textFrame: return String(localized: "text frame", comment: "A role, spoken after an item's name")
        case .section: return String(localized: "section", comment: "A role, spoken after an item's name")
        case .page: return String(localized: "page", comment: "A role, spoken after an item's name")
        case .landmark: return String(localized: "landmark", comment: "A role, spoken after an item's name")
        case .embeddedObject: return String(localized: "embedded object", comment: "A role, spoken after an item's name")
        case .math: return String(localized: "math", comment: "A role, spoken after an item's name")
        case .terminal: return String(localized: "terminal", comment: "A role, spoken after an item's name")
        }
    }

    /// NVDA's silentRolesOnFocus: roles not named when they gain focus.
    /// A web page (Safari, a Mail message) is not called "document" as it is reached: the reading says where you are.
    public static let silentOnFocus: Set<Role> = [.pane, .unknown, .application, .tableCell, .listItem, .tableRow, .menuItem, .checkMenuItem, .treeViewItem, .staticText, .layoutArea, .layoutItem, .cell, .webArea]
    /// NVDA's silentValuesForRoles: roles whose value is never spoken as a value.
    public static let silentValues: Set<Role> = [.checkBox, .radioButton, .link, .menuItem, .application, .busyIndicator, .checkMenuItem, .radioMenuItem]
    /// Containers that are never themselves presented as controls.
    public static let containers: Set<Role> = [.window, .sheet, .dialog, .drawer, .splitPane, .groupBox, .toolBar, .scrollPane, .scrollBar, .separator, .layoutArea, .layoutItem, .pane, .matte, .ruler, .handle, .application, .unknown]
    /// Roles whose text content is navigable (NVDA: _hasNavigableText).
    public static let withNavigableText: Set<Role> = [.editableText, .document, .searchField, .passwordEdit, .terminal, .webArea, .textFrame]
    /// NVDA: focus entering these ancestors is announced (isPresentableFocusAncestor).
    public static let presentableAncestors: Set<Role> = [.dialog, .sheet, .groupBox, .list, .table, .tabControl, .treeView, .outline, .toolBar, .grid]

    /// From an AX role and subrole (NVDA: the API handler's role mapping).
    public static func from(axRole: String, subrole: String?) -> Role {
        switch subrole ?? "" {
        case "AXSearchField": return .searchField
        case "AXSecureTextField": return .passwordEdit
        case "AXTabButton": return .tab
        case "AXDialog", "AXSystemDialog": return .dialog
        case "AXOutlineRow": return .treeViewItem
        case "AXToggle", "AXToggleButton": return .toggleButton   // AXToggleButton: Chromium's aria-pressed (Day 3)
        case "AXApplicationDialog", "AXApplicationAlertDialog", "AXApplicationAlert": return .dialog
        case "AXSwitch": return .switchControl   // "switch, on", as VoiceOver says it (System Settings, 10 Oct 2026)
        case "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton", "AXToolbarButton": return .button
        case "AXTimeline", "AXRatingIndicator": return .slider
        case "AXSortButton": return .button
        case "AXContentList", "AXDescriptionList": return .list
        case "AXDefinition", "AXTerm": return .staticText
        case "AXLandmarkMain", "AXLandmarkNavigation", "AXLandmarkBanner", "AXLandmarkContentInfo", "AXLandmarkSearch", "AXLandmarkComplementary", "AXLandmarkRegion": return .landmark
        default: break
        }
        switch axRole {
        case "AXWindow": return .window
        case "AXSheet": return .sheet
        case "AXDrawer": return .drawer
        case "AXApplication": return .application
        case "AXGroup": return .groupBox
        case "AXSplitGroup": return .splitPane
        case "AXSplitter": return .separator
        case "AXToolbar": return .toolBar
        case "AXScrollArea": return .scrollPane
        case "AXScrollBar": return .scrollBar
        case "AXMenuBar": return .menuBar
        case "AXMenuBarItem": return .menuItem
        case "AXMenu": return .menu
        case "AXMenuItem": return .menuItem
        case "AXButton": return .button
        case "AXMenuButton": return .menuButton
        case "AXCheckBox": return .checkBox
        case "AXRadioButton": return .radioButton
        case "AXLink": return .link
        case "AXComboBox": return .comboBox
        case "AXPopUpButton": return .popUpButton
        case "AXIncrementor": return .spinButton
        case "AXSlider": return .slider
        case "AXTextField": return .editableText
        case "AXTextArea": return .editableText
        case "AXStaticText": return .staticText
        case "AXHeading": return .heading
        case "AXList": return .list
        case "AXTable": return .table
        case "AXRow": return .tableRow
        case "AXColumn": return .tableColumn
        case "AXCell": return .tableCell
        case "AXOutline": return .treeView
        case "AXBrowser": return .browser
        case "AXTabGroup": return .tabControl
        case "AXProgressIndicator": return .progressBar
        case "AXBusyIndicator": return .busyIndicator
        case "AXLevelIndicator": return .levelIndicator
        case "AXColorWell": return .colorChooser
        case "AXImage": return .graphic
        case "AXDateField": return .dateEditor
        case "AXTimeField": return .timeEditor
        case "AXHelpTag": return .toolTip
        case "AXLayoutArea": return .layoutArea
        case "AXLayoutItem": return .layoutItem
        case "AXHandle": return .handle
        case "AXGrid": return .grid
        case "AXMatte": return .matte
        case "AXRuler", "AXRulerMarker": return .ruler
        case "AXValueIndicator": return .valueIndicator
        case "AXDisclosureTriangle": return .disclosureTriangle
        case "AXDockItem": return .dockItem
        case "AXWebArea": return .webArea
        case "AXRelevanceIndicator": return .levelIndicator
        // Preview's PDF pages and its segmented tool groups read as "unknown" (Day 2, 10 Oct 2026).
        case "AXPage": return .page
        case "AXListMarker": return .staticText   // "1", not "unknown, 1" (a web list's numbers; Day 4)
        case "AXRadioGroup": return .groupBox
        default: return .unknown
        }
    }
}

public enum State: String, Codable, CaseIterable {
    case unavailable, focused, selected, busy, pressed, checked, halfChecked, readOnly, expanded, collapsed, invisible
    case hasPopup, protected, required, editable, multiLine, focusable, selectable, modal, defaultButton, on, off, invalidEntry, sorted

    nonisolated public var displayString: String {
        switch self {
        case .unavailable: return String(localized: "unavailable", comment: "A state, spoken after an item's role")
        case .focused: return String(localized: "focused", comment: "A state, spoken after an item's role")
        case .selected: return String(localized: "selected", comment: "A state, spoken after an item's role")
        case .busy: return String(localized: "busy", comment: "A state, spoken after an item's role")
        case .pressed: return String(localized: "pressed", comment: "A state, spoken after an item's role")
        case .checked: return String(localized: "checked", comment: "A state, spoken after an item's role")
        case .halfChecked: return String(localized: "half checked", comment: "A state, spoken after an item's role")
        case .readOnly: return String(localized: "read only", comment: "A state, spoken after an item's role")
        case .expanded: return String(localized: "expanded", comment: "A state, spoken after an item's role")
        case .collapsed: return String(localized: "collapsed", comment: "A state, spoken after an item's role")
        case .invisible: return String(localized: "invisible", comment: "A state, spoken after an item's role")
        case .hasPopup: return String(localized: "submenu", comment: "A state, spoken after an item's role")
        case .protected: return String(localized: "protected", comment: "A state, spoken after an item's role")
        case .required: return String(localized: "required", comment: "A state, spoken after an item's role")
        case .editable: return String(localized: "editable", comment: "A state, spoken after an item's role")
        case .multiLine: return String(localized: "multi line", comment: "A state, spoken after an item's role")
        case .focusable: return String(localized: "focusable", comment: "A state, spoken after an item's role")
        case .selectable: return String(localized: "selectable", comment: "A state, spoken after an item's role")
        case .modal: return String(localized: "modal", comment: "A state, spoken after an item's role")
        case .defaultButton: return String(localized: "default", comment: "A state, spoken after an item's role")
        case .on: return String(localized: "on", comment: "A state, spoken after an item's role")
        case .off: return String(localized: "off", comment: "A state, spoken after an item's role")
        case .invalidEntry: return String(localized: "invalid entry", comment: "A state, spoken after an item's role")
        case .sorted: return String(localized: "sorted", comment: "A state, spoken after an item's role")
        }
    }
    /// NVDA: _negativeStateLabels, spoken when a state the user expects is absent.
    nonisolated public var negativeDisplayString: String {
        switch self {
        case .selected: return String(localized: "not selected", comment: "A state that is absent")
        case .pressed: return String(localized: "not pressed", comment: "A state that is absent")
        case .checked: return String(localized: "not checked", comment: "A state that is absent")
        case .on: return String(localized: "off", comment: "A state that is absent")
        default: return String(localized: "not \(displayString)", comment: "A state that is absent: %@ is the state")
        }
    }

    /// NVDA: states never spoken on focus (the focus itself, selectability…).
    public static let silentOnFocus: Set<State> = [.focused, .focusable, .selectable, .editable, .invisible, .multiLine, .modal]
}

/// NVDA's processAndLabelStates, for speech: which states to say and which absences to name.
public func statesSpeech(role: Role, states: Set<State>, reason: OutputReason) -> [String] {
    var out: [String] = []
    var positive = states.subtracting(State.silentOnFocus)
    // A check box or radio button that is not checked says so (NVDA's negative states).
    if role == .checkBox, !states.contains(.checked), !states.contains(.halfChecked) { out.append(State.checked.negativeDisplayString) }
    if role == .toggleButton, !states.contains(.pressed), !states.contains(.on) { out.append(State.pressed.negativeDisplayString) }
    if role == .switchControl, !states.contains(.on) { out.append(State.on.negativeDisplayString) }
    // Collapsed/expanded only matter on things that can open.
    if ![.treeViewItem, .disclosureTriangle, .comboBox, .popUpButton, .menuButton, .button, .tableRow].contains(role) {
        positive.remove(.collapsed); positive.remove(.expanded)
    }
    if role == .button { positive.remove(.collapsed) }   // Chromium reports AXExpanded false on every button
    // "selected" on the focused item of a single selection is redundant (NVDA drops it on focus).
    // (Not a tab: on the Mac the arrows move focus between tabs without switching, so which tab is showing is news;
    // Output could not be told from Input in System Settings' Sound, 10 Oct 2026.)
    if reason == .focus, [.listItem, .tableRow, .treeViewItem, .menuItem, .tableCell].contains(role) { positive.remove(.selected) }
    for s in State.allCases where positive.contains(s) { out.append(s.displayString) }
    return out
}

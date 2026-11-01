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
    public var displayString: String {
        switch self {
        case .unknown: return "unknown"; case .window: return "window"; case .dialog: return "dialog"; case .sheet: return "sheet"
        case .drawer: return "drawer"; case .application: return "application"; case .pane: return "pane"; case .groupBox: return "grouping"
        case .splitPane: return "split pane"; case .separator: return "separator"; case .toolBar: return "tool bar"; case .scrollPane: return "scroll pane"
        case .scrollBar: return "scroll bar"; case .statusBar: return "status bar"; case .menuBar: return "menu bar"; case .menu: return "menu"
        case .menuItem: return "menu item"; case .checkMenuItem: return "check menu item"; case .radioMenuItem: return "radio menu item"; case .popupMenu: return "popup menu"
        case .button: return "button"; case .menuButton: return "menu button"; case .toggleButton: return "toggle button"; case .switchControl: return "switch"; case .checkBox: return "check box"
        case .radioButton: return "radio button"; case .link: return "link"; case .comboBox: return "combo box"; case .dropDownList: return "drop down list"
        case .popUpButton: return "pop up button"; case .spinButton: return "spin button"; case .slider: return "slider"
        case .editableText: return "edit"; case .document: return "document"; case .searchField: return "search"; case .passwordEdit: return "password edit"
        case .staticText: return "text"; case .heading: return "heading"; case .label: return "label"; case .placeholder: return "placeholder"
        case .list: return "list"; case .listItem: return "list item"; case .table: return "table"; case .tableRow: return "row"; case .tableColumn: return "column"
        case .tableCell: return "cell"; case .tableHeader: return "header"; case .treeView: return "tree view"; case .treeViewItem: return "tree view item"
        case .treeViewButton: return "tree view button"; case .outline: return "tree view"; case .browser: return "browser"
        case .tabControl: return "tab control"; case .tab: return "tab"; case .progressBar: return "progress bar"; case .busyIndicator: return "busy indicator"
        case .levelIndicator: return "level indicator"; case .colorChooser: return "color chooser"; case .image: return "image"; case .graphic: return "graphic"
        case .dateEditor: return "date editor"; case .timeEditor: return "time editor"; case .toolTip: return "tool tip"; case .layoutArea: return "layout area"
        case .layoutItem: return "layout item"; case .handle: return "handle"; case .grid: return "grid"; case .cell: return "cell"; case .matte: return "matte"
        case .ruler: return "ruler"; case .valueIndicator: return "value indicator"; case .incrementor: return "stepper"; case .disclosureTriangle: return "disclosure triangle"
        case .dockItem: return "dock item"; case .webArea: return "document"; case .textFrame: return "text frame"; case .section: return "section"
        case .page: return "page"; case .landmark: return "landmark"; case .embeddedObject: return "embedded object"; case .math: return "math"; case .terminal: return "terminal"
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

    public var displayString: String {
        switch self {
        case .unavailable: return "unavailable"; case .focused: return "focused"; case .selected: return "selected"; case .busy: return "busy"
        case .pressed: return "pressed"; case .checked: return "checked"; case .halfChecked: return "half checked"; case .readOnly: return "read only"
        case .expanded: return "expanded"; case .collapsed: return "collapsed"; case .invisible: return "invisible"; case .hasPopup: return "submenu"
        case .protected: return "protected"; case .required: return "required"; case .editable: return "editable"; case .multiLine: return "multi line"
        case .focusable: return "focusable"; case .selectable: return "selectable"; case .modal: return "modal"; case .defaultButton: return "default"
        case .on: return "on"; case .off: return "off"; case .invalidEntry: return "invalid entry"; case .sorted: return "sorted"
        }
    }
    /// NVDA: _negativeStateLabels, spoken when a state the user expects is absent.
    public var negativeDisplayString: String {
        switch self {
        case .selected: return "not selected"; case .pressed: return "not pressed"; case .checked: return "not checked"; case .on: return "off"
        default: return "not \(displayString)"
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

import AppKit
import PulliProtocol
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Focused Browse Commands

/// Commands and flags published by BrowseView when active in the focused scene.
@MainActor
struct BrowseCommands {
    var hasSelection: Bool
    var copySelected: () -> Void
    var canCopy: Bool
    var copy: () -> Void
    var canPaste: Bool
    var paste: () -> Void
    var canSelectAll: Bool
    var selectAll: () -> Void
    var canDelete: Bool
    var delete: () -> Void
    var layout: BrowseOptions.Layout
    var setLayout: (BrowseOptions.Layout) -> Void
    var sortKey: BrowseOptions.SortKey
    var setSortKey: (BrowseOptions.SortKey) -> Void
    var ascending: Bool
    var setAscending: (Bool) -> Void
}

struct BrowseCommandsKey: FocusedValueKey {
    typealias Value = BrowseCommands
}

extension FocusedValues {
    var browseCommands: BrowseCommands? {
        get { self[BrowseCommandsKey.self] }
        set { self[BrowseCommandsKey.self] = newValue }
    }
}

// MARK: - Text Field Inspection and Seams

/// Inspects the key window to determine whether a text field currently has focus.
@MainActor
enum TextEditorFocus {
    static var activeTextView: NSTextView? {
        NSApp.keyWindow?.firstResponder as? NSTextView
    }

    static var isEditingText: Bool {
        activeTextView != nil
    }

    static var hasTextSelection: Bool {
        guard let textView = activeTextView else { return false }
        return textView.selectedRange().length > 0
    }

    static var hasText: Bool {
        guard let textView = activeTextView else { return false }
        return !textView.string.isEmpty
    }

    static var canPasteText: Bool {
        guard let textView = activeTextView, textView.isEditable else { return false }
        return NSPasteboard.general.types?.contains(.string) == true
    }
}

/// Pure functions for verifying menu item validation logic in unit tests.
/// Whether each Edit command has something to act on. Menu items stay enabled (SwiftUI does not
/// refresh a command's disabled state when the first responder changes, so a greyed-out Copy
/// could block copying text in the search field); actions decide at click time instead.
enum EditCommandRouter {
    static func canCut(isEditingText: Bool, hasTextSelection: Bool) -> Bool {
        isEditingText && hasTextSelection
    }

    static func canCopy(isEditingText: Bool, hasTextSelection: Bool, canCopyBrowser: Bool) -> Bool {
        isEditingText ? hasTextSelection : canCopyBrowser
    }

    static func canPaste(isEditingText: Bool, canPasteText: Bool, canPasteBrowser: Bool) -> Bool {
        isEditingText ? canPasteText : canPasteBrowser
    }

    static func canDelete(isEditingText: Bool, canDeleteBrowser: Bool) -> Bool {
        isEditingText ? true : canDeleteBrowser
    }

    static func canSelectAll(isEditingText: Bool, hasText: Bool, canSelectAllBrowser: Bool) -> Bool {
        isEditingText ? hasText : canSelectAllBrowser
    }
}

// MARK: - All Commands

/// Root command builder combining all menu bar commands.
struct PulliCommands: Commands {
    var body: some Commands {
        PulliAppCommands()
        FileMenuCommands()
        EditMenuCommands()
        ViewMenuCommands()
        GoMenuCommands()
        WindowMenuCommands()
        HelpMenuCommands()
    }
}

// MARK: - Pulli Menu

/// Application menu items: About, Check for Updates / Install Update, Settings.
struct PulliAppCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Pulli") {
                var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
                if let commit = PulliProtocolVersion.commit {
                    options[NSApplication.AboutPanelOptionKey(rawValue: "ApplicationVersion")] = "\(PulliProtocolVersion.buildVersion) (\(commit))"
                }
                options[.credits] = AboutCredits.text
                NSApp.orderFrontStandardAboutPanel(options: options)
            }
        }
        CommandGroup(after: .appInfo) {
            CheckForUpdatesCommand()
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                StatusMenu.openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

// MARK: - File Menu

/// File menu items: copying, browsing, Finder integration, and destination settings.
struct FileMenuCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            FileCommandItems()
        }
    }
}

private struct FileCommandItems: View {
    @FocusedValue(\.browseCommands) private var browseCommands

    var body: some View {
        Button("Copy New Photos") {
            AppDelegate.model?.copyNewPhotos()
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .disabled(AppDelegate.model?.hasNewPhotos != true)

        Button("Copy Selected") {
            browseCommands?.copySelected()
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(browseCommands?.hasSelection != true)

        Divider()

        Button("Open in Finder") {
            AppDelegate.model?.openInFinder()
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .disabled(AppDelegate.model?.canOpenInFinder != true)

        Button("Browse Phone…") {
            AppDelegate.model?.openFolderInBrowser("/")
        }
        .keyboardShortcut("b", modifiers: .command)
        .disabled(AppDelegate.model?.canBrowsePhone != true)

        Button("Storage Map") {
            if let model = AppDelegate.model {
                if model.section != .phone { model.show(.phone) }
                model.openStorageMap()
                AppDelegate.openMainWindow?()
            }
        }
        .disabled(AppDelegate.model?.canOpenStorageMap != true)

        Divider()

        Button("Choose Destination…") {
            AppDelegate.model?.chooseDestination()
        }
        .disabled(AppDelegate.model == nil)

        Button("Show Destination in Finder") {
            AppDelegate.model?.showDestinationInFinder()
        }
        .disabled(AppDelegate.model == nil)
    }
}

// MARK: - Edit Menu

/// Edit menu items: Undo, Redo, Cut, Copy, Paste, Delete, Select All.
struct EditMenuCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            CutCommand()
            CopyCommand()
            PasteCommand()
            DeleteCommand()
            Divider()
            SelectAllCommand()
        }
    }
}

private struct CutCommand: View {
    var body: some View {
        Button("Cut") {
            NSApp.sendAction(#selector(NSTextView.cut(_:)), to: nil, from: nil)
        }
        .keyboardShortcut("x", modifiers: .command)
    }
}

private struct CopyCommand: View {
    @FocusedValue(\.browseCommands) private var browseCommands

    var body: some View {
        Button("Copy") {
            if TextEditorFocus.isEditingText {
                NSApp.sendAction(#selector(NSTextView.copy(_:)), to: nil, from: nil)
            } else {
                browseCommands?.copy()
            }
        }
        .keyboardShortcut("c", modifiers: .command)
    }
}

private struct PasteCommand: View {
    @FocusedValue(\.browseCommands) private var browseCommands

    var body: some View {
        Button("Paste") {
            if TextEditorFocus.isEditingText {
                NSApp.sendAction(#selector(NSTextView.paste(_:)), to: nil, from: nil)
            } else {
                browseCommands?.paste()
            }
        }
        .keyboardShortcut("v", modifiers: .command)
    }
}

private struct DeleteCommand: View {
    @FocusedValue(\.browseCommands) private var browseCommands

    var body: some View {
        Button("Delete") {
            if TextEditorFocus.isEditingText {
                NSApp.sendAction(#selector(NSTextView.delete(_:)), to: nil, from: nil)
            } else {
                browseCommands?.delete()
            }
        }
        .keyboardShortcut(.delete, modifiers: .command)
    }
}

private struct SelectAllCommand: View {
    @FocusedValue(\.browseCommands) private var browseCommands

    var body: some View {
        Button("Select All") {
            if TextEditorFocus.isEditingText {
                NSApp.sendAction(#selector(NSTextView.selectAll(_:)), to: nil, from: nil)
            } else {
                browseCommands?.selectAll()
            }
        }
        .keyboardShortcut("a", modifiers: .command)
    }
}

// MARK: - View Menu

/// View menu items: browser layouts, sorting, section switching, and sidebar toggling.
struct ViewMenuCommands: Commands {
    var body: some Commands {
        CommandGroup(before: .toolbar) {
            ViewCommandItems()
        }
        CommandGroup(after: .toolbar) {
            SidebarCommand()
        }
    }
}

private struct ViewCommandItems: View {
    @FocusedValue(\.browseCommands) private var browseCommands

    var body: some View {
        Button("as Icons") {
            browseCommands?.setLayout(.icons)
        }
        .keyboardShortcut("1", modifiers: .command)
        .disabled(browseCommands == nil)

        Button("as List") {
            browseCommands?.setLayout(.list)
        }
        .keyboardShortcut("2", modifiers: .command)
        .disabled(browseCommands == nil)

        Menu("Sort By") {
            Picker("Sort By", selection: Binding(
                get: { browseCommands?.sortKey ?? .name },
                set: { browseCommands?.setSortKey($0) }
            )) {
                Text("Name").tag(BrowseOptions.SortKey.name)
                Text("Date").tag(BrowseOptions.SortKey.date)
                Text("Size").tag(BrowseOptions.SortKey.size)
                Text("Kind").tag(BrowseOptions.SortKey.kind)
            }
            .pickerStyle(.inline)

            Divider()

            Picker("Order", selection: Binding(
                get: { browseCommands?.ascending ?? true },
                set: { browseCommands?.setAscending($0) }
            )) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
            .pickerStyle(.inline)
        }
        .disabled(browseCommands == nil)

        Divider()

        Button("Phone") {
            AppDelegate.model?.show(.phone)
            AppDelegate.openMainWindow?()
        }
        .keyboardShortcut("1", modifiers: [.command, .option])
        .disabled(AppDelegate.model == nil)

        Button("Copies") {
            AppDelegate.model?.show(.copies)
            AppDelegate.openMainWindow?()
        }
        .keyboardShortcut("2", modifiers: [.command, .option])
        .disabled(AppDelegate.model == nil)

        Button("History") {
            AppDelegate.model?.show(.history)
            AppDelegate.openMainWindow?()
        }
        .keyboardShortcut("3", modifiers: [.command, .option])
        .disabled(AppDelegate.model == nil)
    }
}

/// View › Hide Sidebar / Show Sidebar (⌃⌘S), as in Finder.
struct SidebarCommand: View {
    @AppStorage("sidebarCollapsed") private var collapsed = false

    var body: some View {
        Button(collapsed ? "Show Sidebar" : "Hide Sidebar") {
            collapsed.toggle()
        }
        .keyboardShortcut("s", modifiers: [.command, .control])
    }
}

// MARK: - Go Menu

/// Go menu: navigation back, enclosing folder, and phone destinations.
struct GoMenuCommands: Commands {
    var body: some Commands {
        CommandMenu("Go") {
            Button("Back") {
                AppDelegate.model?.goBackNavigation()
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(AppDelegate.model?.canGoBack != true)

            Button("Enclosing Folder") {
                AppDelegate.model?.goUpToEnclosingFolder()
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(AppDelegate.model?.canGoToEnclosingFolder != true)

            Divider()

            Button("Phone") {
                AppDelegate.model?.openFolderInBrowser("/")
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(AppDelegate.model?.canBrowsePhone != true)

            Button("Camera") {
                if let path = AppDelegate.model?.cameraFolderPath {
                    AppDelegate.model?.openFolderInBrowser(path)
                }
            }
            .disabled(AppDelegate.model?.cameraFolderPath == nil)

            Button("Screenshots") {
                if let path = AppDelegate.model?.screenshotsFolderPath {
                    AppDelegate.model?.openFolderInBrowser(path)
                }
            }
            .disabled(AppDelegate.model?.screenshotsFolderPath == nil)

            Button("Downloads") {
                if let path = AppDelegate.model?.downloadsFolderPath {
                    AppDelegate.model?.openFolderInBrowser(path)
                }
            }
            .disabled(AppDelegate.model?.downloadsFolderPath == nil)
        }
    }
}

// MARK: - Window Menu

/// Window menu: retains system items, removes duplicate Activity Log, and lists windows.
struct WindowMenuCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .windowList) {
            MainWindowCommand()
            OpenActivityCommand()
        }
    }
}

struct OpenActivityCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Activity Log") {
            NSApp.activate()
            if let window = NSApp.windows.first(where: {
                $0.canBecomeMain && !($0 is NSPanel) && ($0.title == "Activity" || $0.identifier?.rawValue == "activity")
            }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: "activity")
            }
        }
        .keyboardShortcut("l", modifiers: [.command, .option])
    }
}

struct MainWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Pulli") {
            NSApp.activate()
            if let window = NSApp.windows.first(where: {
                $0.canBecomeMain && !($0 is NSPanel) && ($0.title == "Pulli" || $0.identifier?.rawValue == "main")
            }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                AppDelegate.openMainWindow?() ?? openWindow(id: "main")
            }
        }
    }
}

// MARK: - Help Menu

/// Help menu: documentation, troubleshooting, updates, feedback, and licences.
struct HelpMenuCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Pulli Help") {
                NSWorkspace.shared.open(URL(string: "https://github.com/ijahongirmirzo/pulli#readme")!)
            }

            Button("Phone Not Showing Up?") {
                NSWorkspace.shared.open(URL(string: "https://support.google.com/android/answer/9064445")!)
            }

            Button("What's New in Pulli") {
                NSWorkspace.shared.open(URL(string: "https://github.com/ijahongirmirzo/pulli/releases")!)
            }

            Divider()

            CheckForUpdatesCommand()

            Button("Send Feedback…") {
                Feedback.open(model: AppDelegate.model)
            }
            .disabled(!Feedback.isAvailable)

            Divider()

            Button("Acknowledgements") {
                openAcknowledgements()
            }
        }
    }
}

private func openAcknowledgements() {
    if let url = Bundle.main.url(forResource: "Licenses", withExtension: nil), FileManager.default.fileExists(atPath: url.path) {
        NSWorkspace.shared.open(url)
    } else if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("Licenses"), FileManager.default.fileExists(atPath: resourceURL.path) {
        NSWorkspace.shared.open(resourceURL)
    } else {
        NSWorkspace.shared.open(URL(string: "https://github.com/ijahongirmirzo/pulli/blob/main/THIRD_PARTY_NOTICES.md")!)
    }
}

// MARK: - Updates Command

/// Check for updates or install a discovered update.
struct CheckForUpdatesCommand: View {
    var body: some View {
        if let version = Updates.shared.available {
            Button("Install Update (\(version))…") {
                Updates.shared.install()
            }
        } else {
            Button("Check for Updates…") {
                Updates.shared.install()
            }
            .disabled(Updates.shared.controller == nil)
        }
    }
}

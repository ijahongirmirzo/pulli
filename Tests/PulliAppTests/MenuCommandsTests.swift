import Foundation
@testable import Pulli
import PulliProtocol
import Testing

@MainActor
@Suite struct MenuCommandsTests {
    @Test func editCommandRouterInTextEditor() {
        // In a text field with text selection
        #expect(EditCommandRouter.canCut(isEditingText: true, hasTextSelection: true))
        #expect(EditCommandRouter.canCopy(isEditingText: true, hasTextSelection: true, canCopyBrowser: false))
        #expect(EditCommandRouter.canPaste(isEditingText: true, canPasteText: true, canPasteBrowser: false))
        #expect(EditCommandRouter.canDelete(isEditingText: true, canDeleteBrowser: false))
        #expect(EditCommandRouter.canSelectAll(isEditingText: true, hasText: true, canSelectAllBrowser: false))

        // In a text field without selection
        #expect(!EditCommandRouter.canCut(isEditingText: true, hasTextSelection: false))
        #expect(!EditCommandRouter.canCopy(isEditingText: true, hasTextSelection: false, canCopyBrowser: true))
        #expect(!EditCommandRouter.canPaste(isEditingText: true, canPasteText: false, canPasteBrowser: true))
        #expect(EditCommandRouter.canDelete(isEditingText: true, canDeleteBrowser: false))
        #expect(!EditCommandRouter.canSelectAll(isEditingText: true, hasText: false, canSelectAllBrowser: true))
    }

    @Test func editCommandRouterInBrowser() {
        // Outside text fields, browser commands take effect
        #expect(!EditCommandRouter.canCut(isEditingText: false, hasTextSelection: false))
        #expect(EditCommandRouter.canCopy(isEditingText: false, hasTextSelection: false, canCopyBrowser: true))
        #expect(!EditCommandRouter.canCopy(isEditingText: false, hasTextSelection: false, canCopyBrowser: false))
        #expect(EditCommandRouter.canPaste(isEditingText: false, canPasteText: false, canPasteBrowser: true))
        #expect(!EditCommandRouter.canPaste(isEditingText: false, canPasteText: true, canPasteBrowser: false))
        #expect(!EditCommandRouter.canDelete(isEditingText: false, canDeleteBrowser: false))
        #expect(EditCommandRouter.canSelectAll(isEditingText: false, hasText: false, canSelectAllBrowser: true))
        #expect(!EditCommandRouter.canSelectAll(isEditingText: false, hasText: true, canSelectAllBrowser: false))
    }

    @Test func browseCommandsState() {
        var copySelectedCalled = false
        var copyCalled = false
        var pasteCalled = false
        var selectAllCalled = false
        var chosenLayout: BrowseOptions.Layout?
        var chosenSort: BrowseOptions.SortKey?
        var chosenAscending: Bool?

        let commands = BrowseCommands(
            hasSelection: true,
            copySelected: { copySelectedCalled = true },
            canCopy: true,
            copy: { copyCalled = true },
            canPaste: true,
            paste: { pasteCalled = true },
            canSelectAll: true,
            selectAll: { selectAllCalled = true },
            canDelete: false,
            delete: {},
            layout: .list,
            setLayout: { chosenLayout = $0 },
            sortKey: .name,
            setSortKey: { chosenSort = $0 },
            ascending: true,
            setAscending: { chosenAscending = $0 }
        )

        #expect(commands.hasSelection)
        #expect(commands.canCopy)
        #expect(commands.canPaste)
        #expect(commands.canSelectAll)
        #expect(!commands.canDelete)

        commands.copySelected()
        #expect(copySelectedCalled)

        commands.copy()
        #expect(copyCalled)

        commands.paste()
        #expect(pasteCalled)

        commands.selectAll()
        #expect(selectAllCalled)

        commands.setLayout(.icons)
        #expect(chosenLayout == .icons)

        commands.setSortKey(.date)
        #expect(chosenSort == .date)

        commands.setAscending(false)
        #expect(chosenAscending == false)
    }

    @Test func appModelNavigationAndQueries() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pulli-menu-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let model = AppModel(mock: true, journalURL: folder.appendingPathComponent("journal.sqlite"))
        await model.start()

        // Wait for ready mock phone and summary
        let deadline = Date().addingTimeInterval(15)
        while !(model.device?.state == .ready && model.device.map { model.summaries[$0.id] != nil } == true) {
            guard Date() < deadline else { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(model.isPhoneReady)
        #expect(model.canBrowsePhone)
        #expect(model.canOpenInFinder)
        #expect(model.canOpenStorageMap)
        #expect(model.cameraFolderPath == "/DCIM/Camera")
        #expect(model.screenshotsFolderPath == "/DCIM/Screenshots")
        #expect(model.downloadsFolderPath == "/Download")

        // Browser navigation
        #expect(!model.canGoBack)
        #expect(!model.canGoToEnclosingFolder)

        model.openFolderInBrowser("/DCIM/Camera")
        #expect(model.browsePath == "/DCIM/Camera")
        #expect(model.canGoBack)
        #expect(model.canGoToEnclosingFolder)

        model.goUpToEnclosingFolder()
        #expect(model.browsePath == "/DCIM")
        #expect(model.canGoToEnclosingFolder)

        model.goUpToEnclosingFolder()
        #expect(model.browsePath == "/")
        #expect(!model.canGoToEnclosingFolder)

        model.goBackNavigation()
        #expect(model.browsePath == nil)
        #expect(!model.canGoBack)

        // Storage map navigation
        model.openStorageMap()
        #expect(model.showingStorageMap)
        #expect(model.canGoBack)

        model.goBackNavigation()
        #expect(!model.showingStorageMap)
        #expect(!model.canGoBack)

        await model.shutdown()
    }
}

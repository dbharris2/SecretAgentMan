import Foundation
@testable import SecretAgentMan
import Testing

struct FileSystemWatcherTests {
    @Test
    @MainActor
    func vcsChangesTriggersMetadataCallback() async {
        let watcher = FileSystemWatcher(debounceInterval: 0)
        let dir = URL(fileURLWithPath: "/tmp/test-repo")

        var directoryChangedCalled = false
        var vcsMetadataChangedCalled = false

        watcher.onDirectoryChanged = { _ in directoryChangedCalled = true }
        watcher.onVCSMetadataChanged = { _ in vcsMetadataChangedCalled = true }

        watcher.handleEvents(directory: dir, paths: [
            "/tmp/test-repo/.jj/op/heads/123abc",
        ])
        await watcher.waitForPendingEvents()

        #expect(!directoryChangedCalled)
        #expect(vcsMetadataChangedCalled)
    }

    @Test
    @MainActor
    func workingCopyChangesTriggersDirectoryCallback() async {
        let watcher = FileSystemWatcher(debounceInterval: 0)
        let dir = URL(fileURLWithPath: "/tmp/test-repo")

        var directoryChangedCalled = false
        var vcsMetadataChangedCalled = false

        watcher.onDirectoryChanged = { _ in directoryChangedCalled = true }
        watcher.onVCSMetadataChanged = { _ in vcsMetadataChangedCalled = true }

        watcher.handleEvents(directory: dir, paths: [
            "/tmp/test-repo/src/main.swift",
        ])
        await watcher.waitForPendingEvents()

        #expect(directoryChangedCalled)
        #expect(!vcsMetadataChangedCalled)
    }

    @Test
    @MainActor
    func mixedChangesTriggersBothCallbacks() async {
        let watcher = FileSystemWatcher(debounceInterval: 0)
        let dir = URL(fileURLWithPath: "/tmp/test-repo")

        var directoryChangedCalled = false
        var vcsMetadataChangedCalled = false

        watcher.onDirectoryChanged = { _ in directoryChangedCalled = true }
        watcher.onVCSMetadataChanged = { _ in vcsMetadataChangedCalled = true }

        watcher.handleEvents(directory: dir, paths: [
            "/tmp/test-repo/.jj/op/heads/123abc",
            "/tmp/test-repo/src/main.swift",
        ])
        await watcher.waitForPendingEvents()

        #expect(directoryChangedCalled)
        #expect(vcsMetadataChangedCalled)
    }

    @Test
    @MainActor
    func gitChangesTriggersMetadataCallback() async {
        let watcher = FileSystemWatcher(debounceInterval: 0)
        let dir = URL(fileURLWithPath: "/tmp/test-repo")

        var directoryChangedCalled = false
        var vcsMetadataChangedCalled = false

        watcher.onDirectoryChanged = { _ in directoryChangedCalled = true }
        watcher.onVCSMetadataChanged = { _ in vcsMetadataChangedCalled = true }

        watcher.handleEvents(directory: dir, paths: [
            "/tmp/test-repo/.git/refs/heads/main",
        ])
        await watcher.waitForPendingEvents()

        #expect(!directoryChangedCalled)
        #expect(vcsMetadataChangedCalled)
    }

    @Test
    @MainActor
    func noEventsTriggersNothing() async {
        let watcher = FileSystemWatcher(debounceInterval: 0)
        let dir = URL(fileURLWithPath: "/tmp/test-repo")

        var directoryChangedCalled = false
        var vcsMetadataChangedCalled = false

        watcher.onDirectoryChanged = { _ in directoryChangedCalled = true }
        watcher.onVCSMetadataChanged = { _ in vcsMetadataChangedCalled = true }

        watcher.handleEvents(directory: dir, paths: [])
        await watcher.waitForPendingEvents()

        #expect(!directoryChangedCalled)
        #expect(!vcsMetadataChangedCalled)
    }
}

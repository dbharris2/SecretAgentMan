import Foundation
import SwiftUI

@MainActor
@Observable
final class RepositoryMonitor {
    let diffService: DiffService

    var fileChanges: [FileChange] = []
    var fullDiff: String = ""
    var branchNames: [String: String] = [:]

    var onDiffChanged: ((URL) -> Void)?
    var onBranchChanged: ((URL) -> Void)?
    var onBranchMetadataChanged: ((URL) -> Void)?

    @ObservationIgnored private let store: AgentStore
    @ObservationIgnored private var fileWatcher = FileSystemWatcher()
    @ObservationIgnored private var bookmarks: [String: String] = [:]
    @ObservationIgnored private var diffGeneration = 0

    init(store: AgentStore, diffService: DiffService = DiffService()) {
        self.store = store
        self.diffService = diffService
    }

    func start() {
        fileWatcher.onDirectoryChanged = { [self] changedFolder in
            refreshBranchName(for: changedFolder)
            onDiffChanged?(changedFolder)
            if let selected = store.selectedAgent,
               selected.folder.standardizedFileURL == changedFolder {
                refreshDiffs()
            }
        }

        fileWatcher.onVCSMetadataChanged = { [self] changedFolder in
            refreshBranchName(for: changedFolder)
            onBranchChanged?(changedFolder)
            if let selected = store.selectedAgent,
               selected.folder.standardizedFileURL == changedFolder {
                refreshDiffs()
            }
        }

        syncWatchedFolders()
        refreshDiffs()
        refreshBranchNames()
    }

    func stop() {
        fileWatcher.unwatchAll()
    }

    func syncWatchedFolders() {
        let desired = Set(store.agents.map(\.folder))
        let current = fileWatcher.watchedDirectories
        for removed in current.subtracting(desired) {
            fileWatcher.unwatch(directory: removed)
        }
        for added in desired.subtracting(current) {
            fileWatcher.watch(directory: added)
        }
    }

    func invalidateDiffs() {
        diffGeneration += 1
        refreshDiffs()
    }

    func refreshDiffs() {
        guard let agent = store.selectedAgent else {
            fileChanges = []
            fullDiff = ""
            return
        }

        let generation = diffGeneration
        let agentId = agent.id
        Task {
            let diff = await diffService.fetchFullDiff(in: agent.folder)
            let changes = diffService.parseChanges(from: diff)
            guard generation == diffGeneration, store.selectedAgentId == agentId else { return }
            fullDiff = diff
            fileChanges = changes
        }
    }

    func bookmark(for folder: URL) -> String? {
        bookmarks[Self.folderKey(folder)]
    }

    private func refreshBranchNames() {
        let folders = Set(store.agents.map(\.folder))
        for folder in folders {
            refreshBranchName(for: folder)
        }
    }

    private func refreshBranchName(for folder: URL) {
        Task {
            let name = await diffService.fetchBranchName(in: folder)
            let key = Self.folderKey(folder)
            let bookmark = await diffService.fetchBookmark(in: folder)
            let changed = branchNames[key] != name || bookmarks[key] != bookmark
            branchNames[key] = name
            bookmarks[key] = bookmark
            if changed {
                onBranchMetadataChanged?(folder)
            }
        }
    }

    private static func folderKey(_ folder: URL) -> String {
        folder.tildeAbbreviatedPath
    }
}

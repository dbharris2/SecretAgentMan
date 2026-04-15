import Foundation
import SwiftUI

@MainActor
@Observable
final class RepositoryMonitor {
    let diffService: DiffService

    var fileChanges: [FileChange] = []
    var fullDiff: String = ""
    var branchNames: [String: String] = [:]
    /// Bumped on any VCS directory change — views can observe this to trigger refreshes.
    var vcsChangeCount = 0

    var onDiffChanged: ((URL) -> Void)?
    var onBranchChanged: ((URL) -> Void)?
    var onBranchMetadataChanged: ((URL) -> Void)?

    @ObservationIgnored private let store: AgentStore
    @ObservationIgnored private var fileWatcher = FileSystemWatcher()
    @ObservationIgnored private var bookmarks: [String: String] = [:]
    @ObservationIgnored private var diffGeneration = 0
    @ObservationIgnored private var branchRefreshDebounceTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var branchRefreshInFlight: Set<String> = []
    @ObservationIgnored private var branchRefreshLastCompletedAt: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var selectedVCSDiffRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var suppressedVCSMetadataUntil: [String: ContinuousClock.Instant] = [:]

    private let branchRefreshDebounceDelay: Duration = .milliseconds(400)
    private let branchRefreshCooldown: Duration = .seconds(2)
    private let selectedVCSDiffDebounceDelay: Duration = .milliseconds(400)
    private let selfInducedVCSSuppression: Duration = .seconds(1)

    init(store: AgentStore, diffService: DiffService = DiffService()) {
        self.store = store
        self.diffService = diffService
    }

    func start() {
        fileWatcher.onDirectoryChanged = { [self] changedFolder in
            vcsChangeCount += 1
            onDiffChanged?(changedFolder)
            if let selected = store.selectedAgent,
               selected.folder.standardizedFileURL == changedFolder {
                refreshDiffs(trigger: "directoryChanged")
            }
        }

        fileWatcher.onVCSMetadataChanged = { [self] changedFolder in
            vcsChangeCount += 1
            guard shouldHandleVCSMetadataChange(for: changedFolder) else { return }
            scheduleBranchRefresh(for: changedFolder, trigger: "vcsMetadataChanged")
            onBranchChanged?(changedFolder)
            if let selected = store.selectedAgent,
               selected.folder.standardizedFileURL == changedFolder {
                scheduleSelectedVCSDiffRefresh(for: changedFolder, trigger: "vcsMetadataChanged")
            }
        }

        syncWatchedFolders()
        refreshDiffs(trigger: "start")
        refreshBranchNames()
    }

    func stop() {
        fileWatcher.unwatchAll()
        for task in branchRefreshDebounceTasks.values {
            task.cancel()
        }
        branchRefreshDebounceTasks.removeAll()
        selectedVCSDiffRefreshTask?.cancel()
        selectedVCSDiffRefreshTask = nil
    }

    func syncWatchedFolders() {
        let desired = Set(store.agents.map(\.folder))
        let current = fileWatcher.watchedDirectories
        for removed in current.subtracting(desired) {
            fileWatcher.unwatch(directory: removed)
            branchRefreshDebounceTasks.removeValue(forKey: Self.folderKey(removed))?.cancel()
            if store.selectedAgent?.folder.standardizedFileURL == removed {
                selectedVCSDiffRefreshTask?.cancel()
                selectedVCSDiffRefreshTask = nil
            }
        }
        for added in desired.subtracting(current) {
            fileWatcher.watch(directory: added)
        }
    }

    func invalidateDiffs() {
        diffGeneration += 1
        selectedVCSDiffRefreshTask?.cancel()
        selectedVCSDiffRefreshTask = nil
        refreshDiffs(trigger: "invalidateDiffs")
    }

    func refreshDiffs(trigger: String = "manual") {
        guard let agent = store.selectedAgent else {
            fileChanges = []
            fullDiff = ""
            return
        }

        let refreshStart = CFAbsoluteTimeGetCurrent()
        let generation = diffGeneration
        let agentId = agent.id
        let folder = agent.folder
        let diffService = self.diffService
        Task.detached(priority: .background) {
            let t0 = CFAbsoluteTimeGetCurrent()
            let diff = await diffService.fetchFullDiff(in: folder)
            PerfLogger.log("fetchFullDiff", start: t0, details: "folder=\(folder.lastPathComponent)")
            let changes = diffService.parseChanges(from: diff)
            await MainActor.run {
                guard generation == self.diffGeneration, self.store.selectedAgentId == agentId else { return }
                self.fullDiff = diff
                self.fileChanges = changes
                PerfLogger.log("refreshDiffs.total", start: refreshStart, details: "folder=\(folder.lastPathComponent) trigger=\(trigger)")
            }
        }
    }

    func bookmark(for folder: URL) -> String? {
        bookmarks[Self.folderKey(folder)]
    }

    private func refreshBranchNames() {
        let folders = Set(store.agents.map(\.folder))
        for folder in folders {
            refreshBranchName(for: folder, trigger: "startup")
        }
    }

    private func scheduleSelectedVCSDiffRefresh(for folder: URL, trigger: String) {
        selectedVCSDiffRefreshTask?.cancel()
        selectedVCSDiffRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: self!.selectedVCSDiffDebounceDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      let selected = self.store.selectedAgent,
                      selected.folder.standardizedFileURL == folder
                else { return }
                self.suppressVCSMetadataChange(for: folder)
                self.refreshDiffs(trigger: "\(trigger):debouncedSelectedRepo")
            }
        }
    }

    private func scheduleBranchRefresh(for folder: URL, trigger: String) {
        let key = Self.folderKey(folder)
        branchRefreshDebounceTasks[key]?.cancel()
        branchRefreshDebounceTasks[key] = Task { [weak self] in
            do {
                try await Task.sleep(for: self!.branchRefreshDebounceDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.branchRefreshDebounceTasks.removeValue(forKey: key)
                self?.refreshBranchNameIfNeeded(for: folder, trigger: "\(trigger):debounced")
            }
        }
    }

    private func refreshBranchNameIfNeeded(for folder: URL, trigger: String) {
        let key = Self.folderKey(folder)
        let now = ContinuousClock.now

        if branchRefreshInFlight.contains(key) { return }

        if let lastCompletedAt = branchRefreshLastCompletedAt[key] {
            let elapsed = lastCompletedAt.duration(to: now)
            if elapsed < branchRefreshCooldown { return }
        }

        refreshBranchName(for: folder, trigger: trigger)
    }

    private func refreshBranchName(for folder: URL, trigger: String) {
        let refreshStart = CFAbsoluteTimeGetCurrent()
        let diffService = self.diffService
        let key = Self.folderKey(folder)
        branchRefreshInFlight.insert(key)
        suppressVCSMetadataChange(for: folder)
        Task.detached(priority: .background) {
            async let nameTask = diffService.fetchBranchName(in: folder)
            async let bookmarkTask = diffService.fetchBookmark(in: folder)
            let (name, bookmark) = await (nameTask, bookmarkTask)
            await MainActor.run {
                let changed = self.branchNames[key] != name || self.bookmarks[key] != bookmark
                self.branchNames[key] = name
                self.bookmarks[key] = bookmark
                self.branchRefreshInFlight.remove(key)
                self.branchRefreshLastCompletedAt[key] = .now
                PerfLogger.log("refreshBranchName.total", start: refreshStart, details: "folder=\(folder.lastPathComponent) trigger=\(trigger)")
                if changed {
                    self.onBranchMetadataChanged?(folder)
                }
            }
        }
    }

    private func shouldHandleVCSMetadataChange(for folder: URL) -> Bool {
        let key = Self.folderKey(folder)
        let now = ContinuousClock.now
        if let suppressedUntil = suppressedVCSMetadataUntil[key], now < suppressedUntil {
            return false
        }
        return true
    }

    private func suppressVCSMetadataChange(for folder: URL) {
        suppressedVCSMetadataUntil[Self.folderKey(folder)] = ContinuousClock.now.advanced(by: selfInducedVCSSuppression)
    }

    private static func folderKey(_ folder: URL) -> String {
        folder.tildeAbbreviatedPath
    }
}

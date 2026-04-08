import CoreServices
import Foundation

/// Bridges FSEvents C callback back to Swift. Not actor-isolated since
/// the callback fires on an arbitrary thread.
private final class FileSystemWatcherContext {
    weak var watcher: FileSystemWatcher?
    let directory: URL

    init(watcher: FileSystemWatcher, directory: URL) {
        self.watcher = watcher
        self.directory = directory
    }
}

/// Watches directories for file system changes using macOS FSEvents.
/// Provides debounced, filtered notifications — ignores VCS-internal churn
/// (.git/, .jj/) and coalesces rapid changes.
@MainActor
final class FileSystemWatcher {
    private var streams: [URL: FSEventStreamRef] = [:]
    private var contexts: [URL: FileSystemWatcherContext] = [:]
    private var watchCounts: [URL: Int] = [:]

    var watchedDirectories: Set<URL> {
        Set(watchCounts.keys)
    }

    private var debounceTasks: [URL: Task<Void, Never>] = [:]
    private let debounceInterval: UInt64 = 300_000_000 // 300ms in nanoseconds

    /// Called when a watched directory has meaningful file changes (working copy).
    var onDirectoryChanged: ((URL) -> Void)?

    /// Called when VCS metadata changes (.git/ or .jj/) — e.g. jj describe, git commit.
    var onVCSMetadataChanged: ((URL) -> Void)?

    /// Start watching a directory. Reference-counted — safe to call multiple
    /// times for the same URL (e.g. multiple agents sharing a folder).
    func watch(directory: URL) {
        let normalized = directory.standardizedFileURL
        let count = (watchCounts[normalized] ?? 0) + 1
        watchCounts[normalized] = count

        if count > 1 { return } // Already watching

        let context = FileSystemWatcherContext(watcher: self, directory: normalized)
        contexts[normalized] = context

        let pathsToWatch = [normalized.path as CFString] as CFArray
        let rawContext = Unmanaged.passRetained(context).toOpaque()

        var fsContext = FSEventStreamContext(
            version: 0,
            info: rawContext,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let stream = FSEventStreamCreate(
            nil,
            fsEventsCallback,
            &fsContext,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1, // 100ms latency for FSEvents' own coalescing
            UInt32(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagNoDefer
            )
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        streams[normalized] = stream
    }

    /// Stop watching a directory. Only destroys the stream when the last
    /// reference is removed.
    func unwatch(directory: URL) {
        let normalized = directory.standardizedFileURL
        guard let count = watchCounts[normalized], count > 0 else { return }

        let newCount = count - 1
        if newCount > 0 {
            watchCounts[normalized] = newCount
            return
        }

        watchCounts.removeValue(forKey: normalized)
        teardownStream(for: normalized)
    }

    /// Stop watching all directories.
    func unwatchAll() {
        for url in streams.keys {
            teardownStream(for: url)
        }
        watchCounts.removeAll()
    }

    // MARK: - Internal

    func handleEvents(directory: URL, paths: [String]) {
        var hasWorkingCopyChange = false
        var hasVCSChange = false

        for path in paths {
            let relative =
                path.hasPrefix(directory.path)
                    ? String(path.dropFirst(directory.path.count + 1))
                    : path
            if relative.hasPrefix(".git/") || relative.hasPrefix(".git")
                || relative.hasPrefix(".jj/") || relative.hasPrefix(".jj") {
                hasVCSChange = true
            } else {
                hasWorkingCopyChange = true
            }
        }

        if hasWorkingCopyChange {
            debounceTasks[directory]?.cancel()
            debounceTasks[directory] = Task { [weak self, debounceInterval] in
                do {
                    try await Task.sleep(nanoseconds: debounceInterval)
                } catch { return }
                self?.onDirectoryChanged?(directory)
            }
        }

        if hasVCSChange {
            // Use a separate debounce key for VCS metadata
            let vcsKey = directory.appendingPathComponent(".vcs-metadata")
            debounceTasks[vcsKey]?.cancel()
            debounceTasks[vcsKey] = Task { [weak self, debounceInterval] in
                do {
                    try await Task.sleep(nanoseconds: debounceInterval)
                } catch { return }
                self?.onVCSMetadataChanged?(directory)
            }
        }
    }

    private func teardownStream(for url: URL) {
        if let stream = streams.removeValue(forKey: url) {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        if let context = contexts.removeValue(forKey: url) {
            Unmanaged.passUnretained(context).release()
        }
        debounceTasks.removeValue(forKey: url)?.cancel()
    }
}

// MARK: - FSEvents C Callback

private func fsEventsCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ clientCallBackInfo: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let context = Unmanaged<FileSystemWatcherContext>.fromOpaque(info).takeUnretainedValue()
    let directory = context.directory

    // Extract paths from the callback
    let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    var paths: [String] = []
    for i in 0 ..< numEvents {
        if let cfPath = CFArrayGetValueAtIndex(cfPaths, i) {
            let path = Unmanaged<CFString>.fromOpaque(cfPath).takeUnretainedValue() as String
            paths.append(path)
        }
    }

    // Dispatch back to main actor
    let watcher = context.watcher
    Task { @MainActor in
        watcher?.handleEvents(directory: directory, paths: paths)
    }
}

import Foundation
import CoreServices

/// Watches a single file for external modifications via FSEvents. The
/// stream is opened on the file's parent directory (FSEvents observes
/// directories, not files) and per-event paths are filtered down to the
/// watched URL.
///
/// Bursty writers — agents streaming a long file in chunks, editors that
/// write through a temp + rename, file-syncing daemons — would trigger
/// many reloads in quick succession. To avoid reloading mid-write, every
/// event schedules a debounced size-stability check: only when the file
/// size has held steady for ~200ms do we report the change.
@MainActor
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private var debounceWorkItem: DispatchWorkItem?
    private var lastSeenSize: UInt64 = 0

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url.standardizedFileURL
        self.onChange = onChange
        start()
    }

    deinit {
        // Cleanup is scheduled to the main actor; can't await from deinit.
        // The stream + work item retain only weak/value state, so leaking
        // them across the dealloc boundary is benign — but invalidate the
        // stream synchronously here so OS-level resources are released.
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    // MARK: - Stream lifecycle

    private func start() {
        let parent = url.deletingLastPathComponent().path
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagUseCFTypes
        )
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, paths, _, _ in
                guard let info else { return }
                // With kFSEventStreamCreateFlagUseCFTypes, `paths` is a
                // CFArrayRef of CFStrings — bridge it through Unmanaged
                // rather than reinterpreting raw memory.
                let cfArray = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue()
                let pathStrings = (cfArray as? [String]) ?? []
                let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
                // Dispatch queue is already main (set via FSEventStreamSetDispatchQueue),
                // so we can synchronously hop into the actor's isolation.
                MainActor.assumeIsolated {
                    watcher.handleEventPaths(pathStrings)
                }
            },
            &context,
            [parent] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,   // latency seconds: small so events arrive quickly
            flags
        ) else {
            return
        }
        self.stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
        lastSeenSize = currentFileSize()
    }

    // MARK: - Event handling

    private func handleEventPaths(_ paths: [String]) {
        let target = url.path
        for path in paths {
            // FSEvents may return a canonicalized path; standardize both
            // ends so symlinks / `/private/var` aliases compare equal.
            if URL(fileURLWithPath: path).standardizedFileURL.path == target {
                scheduleStabilityCheck()
                return
            }
        }
    }

    /// Schedule a size-stability check 200ms in the future. If a fresh
    /// event arrives before then, the previous check is cancelled and a
    /// new one queued — so a long burst of writes only triggers one
    /// reload, after the writer has stopped.
    private func scheduleStabilityCheck() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let size = self.currentFileSize()
            if size == self.lastSeenSize && size > 0 {
                self.onChange()
            } else {
                self.lastSeenSize = size
                // Size still moving — give it another 200ms.
                self.scheduleStabilityCheck()
            }
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func currentFileSize() -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? UInt64) ?? 0
    }
}

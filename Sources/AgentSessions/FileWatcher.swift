import CoreServices
import Foundation

/// Watches paths recursively via FSEvents and reports changed paths on a
/// background queue. Coalesces bursts through the FSEvents latency window.
///
/// `@unchecked Sendable`: the stream is created once during `init` and only torn
/// down in `stop()`/`deinit`; FSEvents delivers callbacks on our own serial queue.
final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "claude-sessions.file-watcher")
    private let onChange: ([String]) -> Void

    /// - Parameters:
    ///   - paths: files or directories to watch (directories are watched recursively)
    ///   - latency: seconds FSEvents coalesces events over before delivering
    init(paths: [String], latency: TimeInterval = 0.4, onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
        start(paths: paths, latency: latency)
    }

    deinit { stop() }

    private func start(paths: [String], latency: TimeInterval) {
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // UseCFTypes makes `eventPaths` a CFArray of CFString. Without it FSEvents
        // hands back a raw `char **`, which cannot be bridged as an object.
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info, count > 0 else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] ?? []
            guard !paths.isEmpty else { return }
            watcher.onChange(paths)
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

/// Collapses rapid-fire calls into one trailing call after `delay`.
final class Debouncer {
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private var workItem: DispatchWorkItem?

    init(delay: TimeInterval, queue: DispatchQueue = .main) {
        self.delay = delay
        self.queue = queue
    }

    func call(_ block: @escaping () -> Void) {
        workItem?.cancel()
        let item = DispatchWorkItem(block: block)
        workItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}

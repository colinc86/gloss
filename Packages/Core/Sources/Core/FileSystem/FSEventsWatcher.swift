import CoreServices
import Foundation

/// Wraps an `FSEventStream` as an `AsyncStream`. The stream stops, invalidates, and releases itself when the
/// consumer cancels. FSEvents owns the only strong reference to the callback box through the context's
/// retain and release callbacks, so a callback already queued behind teardown can never touch freed memory.
public enum FSEventsWatcher {
    private final class Box: Sendable {
        let continuation: AsyncStream<FileSystemEvent>.Continuation
        init(_ continuation: AsyncStream<FileSystemEvent>.Continuation) { self.continuation = continuation }
    }

    private final class Handle: @unchecked Sendable {
        let stream: FSEventStreamRef
        let queue: DispatchQueue
        init(stream: FSEventStreamRef, queue: DispatchQueue) {
            self.stream = stream
            self.queue = queue
        }

        func tearDown() {
            queue.async { [self] in
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
        }
    }

    public static func events(forPaths paths: [String], latency: TimeInterval = 0.3) -> AsyncStream<FileSystemEvent> {
        AsyncStream { continuation in
            let box = Unmanaged.passRetained(Box(continuation))
            var context = FSEventStreamContext(
                version: 0, info: box.toOpaque(),
                retain: { pointer in
                    guard let pointer else { return nil }
                    return UnsafeRawPointer(Unmanaged<Box>.fromOpaque(pointer).retain().toOpaque())
                },
                release: { pointer in
                    guard let pointer else { return }
                    Unmanaged<Box>.fromOpaque(pointer).release()
                },
                copyDescription: nil
            )
            let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
            let stream = FSEventStreamCreate(
                nil, callback, &context, paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
            )
            // FSEvents retained the box through the context; drop our own reference either way.
            box.release()
            guard let stream else {
                continuation.finish()
                return
            }
            let queue = DispatchQueue(label: "com.cnc.Gloss.fsevents")
            FSEventStreamSetDispatchQueue(stream, queue)
            let handle = Handle(stream: stream, queue: queue)
            guard FSEventStreamStart(stream) else {
                handle.tearDown()
                continuation.finish()
                return
            }
            continuation.onTermination = { _ in handle.tearDown() }
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
        guard let info else { return }
        let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
        guard let paths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] else { return }
        var changed: [String] = []
        for index in 0..<count {
            let flags = eventFlags[index]
            let path = paths[index]
            let mustRescan = flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
            let rootChanged = flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0
            if mustRescan || rootChanged {
                box.continuation.yield(.rescan(path))
            } else {
                changed.append(path)
            }
        }
        if !changed.isEmpty { box.continuation.yield(.changed(changed)) }
    }
}

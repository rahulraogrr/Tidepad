import CoreServices
import Foundation

/// Tells Tidepad which folders changed on disk, using FSEvents (the macOS service Finder uses), so the
/// sidebar and open files follow changes made by Claude Code, git or a build without a manual refresh. Events arrive on
/// the main queue, grouped over `latency` seconds, as folder paths.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let changed: ([String]) -> Void

    convenience init?(folder: URL, latency: TimeInterval = 0.3, changed: @escaping ([String]) -> Void) {
        self.init(folders: [folder], latency: latency, changed: changed)
    }

    /// Watches several folders (and everything inside them) with one stream.
    init?(folders: [URL], latency: TimeInterval = 0.3, changed: @escaping ([String]) -> Void) {
        self.changed = changed
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            watcher.changed(list.compactMap { $0 as? String })
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, folders.map(\.path) as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

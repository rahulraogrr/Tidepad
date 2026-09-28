import Foundation

/// Watches one open document's file with NSFilePresenter, the native way to learn that another app
/// changed, moved or deleted it. Tidepad's own saves are coordinated with this presenter, so they
/// don't notify it. Callbacks arrive on the main queue.
///
/// File coordination talks to presenters on their own queue, which is deliberately not the main queue:
/// a coordinated write made on the main thread waits for every other presenter of the file, so a
/// presenter on the main queue would deadlock it. Notifications are passed on to the main queue.
final class DocumentFilePresenter: NSObject, NSFilePresenter {
    let documentID: UUID
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Tidepad.DocumentFilePresenter"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    var onChange: (() -> Void)?
    var onMove: ((URL) -> Void)?
    var onDelete: (() -> Void)?

    private let lock = NSLock()
    private var url: URL
    /// Read by the file coordination system from its own threads.
    var presentedItemURL: URL? { lock.withLock { url } }

    init(documentID: UUID, url: URL) {
        self.documentID = documentID
        self.url = url
        super.init()
    }

    func presentedItemDidChange() {
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    func presentedItemDidMove(to newURL: URL) {
        lock.withLock { url = newURL }
        DispatchQueue.main.async { [weak self] in self?.onMove?(newURL) }
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async { [weak self] in self?.onDelete?() }
        completionHandler(nil)
    }
}

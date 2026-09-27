import Foundation

/// Watches one open document's file with NSFilePresenter, the native way to learn that another app
/// changed, moved or deleted it. Tidepad's own saves are coordinated with this presenter, so they
/// don't notify it. Callbacks arrive on the main queue.
final class DocumentFilePresenter: NSObject, NSFilePresenter {
    let documentID: UUID
    let presentedItemOperationQueue = OperationQueue.main
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

    func presentedItemDidChange() { onChange?() }

    func presentedItemDidMove(to newURL: URL) {
        lock.withLock { url = newURL }
        onMove?(newURL)
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        onDelete?()
        completionHandler(nil)
    }
}

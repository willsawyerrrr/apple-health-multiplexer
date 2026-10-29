import Foundation

/// Uploads local profile changes to the household, retrying on every sync, and merges the household's.
@MainActor
final class ProfileSyncCoordinator {
    private let book: ProfileBook
    private let sync: ProfileSync
    private let log: (String) -> Void
    private var isFlushing = false

    init(book: ProfileBook, sync: ProfileSync, log: @escaping (String) -> Void) {
        self.book = book
        self.sync = sync
        self.log = log
        book.onChange = { [weak self] in
            Task { await self?.flush() }
        }
    }

    /// Uploads profiles with pending changes, stopping at the first failure, which is logged and retried
    /// on the next flush; returns whether nothing is pending.
    @discardableResult
    func flush() async -> Bool {
        guard !isFlushing else { return false }
        isFlushing = true
        defer { isFlushing = false }
        while let profile = book.pendingUploads.first {
            do {
                book.finishUpload(of: profile, result: try await sync.uploadProfile(profile))
            } catch {
                log("profile \(profile.slot) not saved to the household, will retry: \(error)")
                return false
            }
        }
        return true
    }

    /// Merges profile changes the last household fetch saw; returns whether any name or flag changed.
    @discardableResult
    func pull() -> Bool {
        book.apply(sync.takeProfileChanges())
    }
}

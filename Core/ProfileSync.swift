import Foundation

/// The household's shared copy of the profiles, one record per thermometer slot.
protocol ProfileSync: AnyObject {
    /// Uploads `profile` and returns the household's version afterwards: `profile` itself, or a
    /// newer version another phone saved first.
    func uploadProfile(_ profile: Profile) async throws -> ProfileChange
    /// Profile changes seen by household fetches since the previous call.
    func takeProfileChanges() -> [ProfileChange]
}

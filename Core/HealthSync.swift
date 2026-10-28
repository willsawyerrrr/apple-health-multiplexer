import Foundation
import Observation

/// Writes readings for this phone's owner to Apple Health and deletes those that were deleted, retrying
/// until each write or deletion succeeds.
@MainActor @Observable
final class HealthSync {
    private static let profileKey = "myProfile"
    private static let pendingKey = "pendingHealthSamples"
    private static let writtenKey = "writtenHealthSamples"
    private static let deletionsKey = "pendingHealthDeletions"

    /// The thermometer profile (0, 1 or 2) that belongs to this phone's owner; local only.
    var myProfile: Int? {
        didSet {
            guard myProfile != oldValue else { return }
            if let myProfile {
                defaults.set(myProfile, forKey: Self.profileKey)
                backfill()
                Task { await requestAccess() }
            } else {
                defaults.removeObject(forKey: Self.profileKey)
            }
        }
    }
    /// The readings kept on this phone, excluding deleted ones; queued for `myProfile` when it is set.
    var storedReadings: () -> [ThermometerReading] = { [] }
    private(set) var pending: [HealthSample]
    /// Record names already handed to Health; never queued again, so samples deleted in Health stay deleted.
    private(set) var written: Set<String>
    /// Sync identifiers of samples still to be deleted from Health.
    private(set) var pendingDeletions: [String]
    /// Whether write access to Health is denied, or why requesting it failed; `nil` when there is nothing to report.
    private(set) var accessProblem: String?

    private let writer: HealthWriter
    private let defaults: UserDefaults
    private let isTracked: (Int) -> Bool
    private var isFlushing = false
    private var accessTask: Task<Void, Never>?

    /// `isTracked` says whether a profile slot's readings may be written to Health.
    init(writer: HealthWriter, defaults: UserDefaults = .standard, isTracked: @escaping (Int) -> Bool = { _ in true }) {
        self.writer = writer
        self.defaults = defaults
        self.isTracked = isTracked
        myProfile = defaults.object(forKey: Self.profileKey) as? Int
        pending = defaults.data(forKey: Self.pendingKey)
            .flatMap { try? JSONDecoder().decode([HealthSample].self, from: $0) } ?? []
        written = Set(defaults.stringArray(forKey: Self.writtenKey) ?? [])
        pendingDeletions = defaults.stringArray(forKey: Self.deletionsKey) ?? []
    }

    /// Queues the reading when it belongs to `myProfile` and that profile is tracked, then tries to write it.
    func submit(_ reading: ThermometerReading) {
        guard enqueue(reading) else { return }
        persist()
        Task { await flush() }
    }

    /// Queues every stored reading for `myProfile` when that profile is set and tracked, then tries to write them.
    func backfill() {
        var queued = false
        for reading in storedReadings() where enqueue(reading) { queued = true }
        guard queued else { return }
        persist()
        Task { await flush() }
    }

    private func enqueue(_ reading: ThermometerReading) -> Bool {
        guard let profile = reading.profile, profile == myProfile, isTracked(profile),
            let name = SyncReading(reading)?.recordName,
            !written.contains(name), !pending.contains(where: { $0.name == name })
        else { return false }
        pending.append(HealthSample(name: name, celsius: reading.celsius, measuredAt: reading.measuredAt))
        return true
    }

    /// Drops the readings' unwritten samples, forgets that they were written and queues the deletion of any
    /// sample already in Health, then tries to delete it.
    func remove(recordNames: [String]) {
        guard !recordNames.isEmpty else { return }
        pending.removeAll { recordNames.contains($0.name) }
        written.subtract(recordNames)
        pendingDeletions += recordNames.filter { !pendingDeletions.contains($0) }
        persist()
        Task { await flush() }
    }

    /// When `myProfile` is set, asks for write access unless Health has already been asked, then updates `accessProblem`.
    /// Concurrent calls share one request.
    func requestAccess() async {
        if let accessTask { return await accessTask.value }
        guard myProfile != nil else { return }
        let task = Task { @MainActor in
            if writer.writeStatus() == .notDetermined {
                do { try await writer.requestAuthorization() } catch { accessProblem = error.localizedDescription }
            }
            if writer.writeStatus() == .denied {
                accessProblem = "Health access not granted. Enable it in Settings > Health > Data Access & Devices > Kintemp."
            } else if accessProblem?.hasPrefix("Health access not granted") == true {
                accessProblem = nil
            }
        }
        accessTask = task
        await task.value
        accessTask = nil
    }

    /// Requests write access, then writes pending samples in order and deletes the samples queued for
    /// deletion, keeping any that fail. Without write access nothing can have been written or deleted, so
    /// queued deletions are dropped.
    func flush() async {
        guard !isFlushing, !pending.isEmpty || !pendingDeletions.isEmpty else { return }
        isFlushing = true
        defer { isFlushing = false }
        await requestAccess()
        for sample in pending {
            guard pending.contains(sample) else { continue }
            do { try await writer.write(sample) } catch { continue }
            pending.removeAll { $0.name == sample.name }
            written.insert(sample.name)
            persist()
        }
        guard writer.writeStatus() == .authorized else {
            pendingDeletions = []
            persist()
            return
        }
        while let name = pendingDeletions.first {
            do { try await writer.delete(name: name) } catch { return }
            pendingDeletions.removeAll { $0 == name }
            persist()
        }
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(pending), forKey: Self.pendingKey)
        defaults.set(written.sorted(), forKey: Self.writtenKey)
        defaults.set(pendingDeletions, forKey: Self.deletionsKey)
    }
}

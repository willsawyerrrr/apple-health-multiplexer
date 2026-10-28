import Foundation
import Observation

/// Writes readings for this phone's owner to Apple Health, retrying until each write succeeds.
@MainActor @Observable
final class HealthSync {
    private static let profileKey = "myProfile"
    private static let pendingKey = "pendingHealthSamples"

    /// The thermometer profile (0, 1 or 2) that belongs to this phone's owner; local only.
    var myProfile: Int? {
        didSet {
            guard myProfile != oldValue else { return }
            if let myProfile {
                defaults.set(myProfile, forKey: Self.profileKey)
                Task { await requestAccess() }
            } else {
                defaults.removeObject(forKey: Self.profileKey)
            }
        }
    }
    private(set) var pending: [HealthSample]
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
    }

    /// Queues the reading when it belongs to `myProfile` and that profile is tracked, then tries to write it.
    func submit(_ reading: ThermometerReading) {
        guard let profile = reading.profile, profile == myProfile, isTracked(profile),
            let name = SyncReading(reading)?.recordName
        else { return }
        guard !pending.contains(where: { $0.name == name }) else { return }
        pending.append(HealthSample(name: name, celsius: reading.celsius, measuredAt: reading.measuredAt))
        persist()
        Task { await flush() }
    }

    /// Drops the reading's sample if it has not been written yet; a written sample stays in Health.
    func discard(_ reading: ThermometerReading) {
        guard let name = SyncReading(reading)?.recordName, pending.contains(where: { $0.name == name }) else { return }
        pending.removeAll { $0.name == name }
        persist()
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

    /// Requests write access, then writes pending samples in order, keeping any that fail.
    func flush() async {
        guard !isFlushing, !pending.isEmpty else { return }
        isFlushing = true
        defer { isFlushing = false }
        await requestAccess()
        for sample in pending {
            do { try await writer.write(sample) } catch { continue }
            pending.removeAll { $0.name == sample.name }
            persist()
        }
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(pending), forKey: Self.pendingKey)
    }
}

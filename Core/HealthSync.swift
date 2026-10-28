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
            if let myProfile { defaults.set(myProfile, forKey: Self.profileKey) } else { defaults.removeObject(forKey: Self.profileKey) }
        }
    }
    private(set) var pending: [HealthSample]

    private let writer: HealthWriter
    private let defaults: UserDefaults
    private let isTracked: (Int) -> Bool
    private var isFlushing = false

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
        guard let profile = reading.profile, profile == myProfile, isTracked(profile) else { return }
        let name = HealthRecordName.make(profile: profile, measuredAt: reading.measuredAt, celsius: reading.celsius)
        guard !pending.contains(where: { $0.name == name }) else { return }
        pending.append(HealthSample(name: name, celsius: reading.celsius, measuredAt: reading.measuredAt))
        persist()
        Task { await flush() }
    }

    /// Requests write access, then writes pending samples in order, keeping any that fail.
    func flush() async {
        guard !isFlushing, !pending.isEmpty else { return }
        isFlushing = true
        defer { isFlushing = false }
        try? await writer.requestAuthorization()
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

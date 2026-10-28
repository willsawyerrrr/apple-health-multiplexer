import Foundation
import HealthKit

struct HealthKitWriter: HealthWriter {
    private let store = HKHealthStore()
    private let type = HKQuantityType(.bodyTemperature)

    func writeStatus() -> HealthWriteStatus {
        switch store.authorizationStatus(for: type) {
        case .notDetermined: .notDetermined
        case .sharingDenied: .denied
        case .sharingAuthorized: .authorized
        @unknown default: .notDetermined
        }
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try await store.requestAuthorization(toShare: [type], read: [])
    }

    func write(_ sample: HealthSample) async throws {
        let quantity = HKQuantity(unit: .degreeCelsius(), doubleValue: sample.celsius)
        let healthSample = HKQuantitySample(
            type: type,
            quantity: quantity,
            start: sample.measuredAt,
            end: sample.measuredAt,
            metadata: [
                HKMetadataKeySyncIdentifier: sample.name,
                HKMetadataKeySyncVersion: 1,
            ])
        try await store.save(healthSample)
    }
}

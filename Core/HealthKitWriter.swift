import Foundation
import HealthKit

struct HealthKitWriter: HealthWriter {
    private let store = HKHealthStore()
    private let type = HKQuantityType(.bodyTemperature)
    private let device = HKDevice(
        name: "THERMOCARE Smart Thermometer",
        manufacturer: "T&R Biofab",
        model: "MT-3000",
        hardwareVersion: "V1.7",
        firmwareVersion: "V2.0T",
        softwareVersion: "V1.0",
        localIdentifier: nil,
        udiDeviceIdentifier: nil)

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
            device: device,
            metadata: [
                HKMetadataKeySyncIdentifier: sample.name,
                HKMetadataKeySyncVersion: 1,
            ])
        try await store.save(healthSample)
    }

    func delete(name: String) async throws {
        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [name])
        _ = try await store.deleteObjects(of: type, predicate: predicate)
    }
}

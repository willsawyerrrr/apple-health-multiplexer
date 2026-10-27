import CoreBluetooth
import Foundation

/// CoreBluetooth implementation of `ThermometerClient`. Keeps a pending
/// connect with state restoration and runs the read-only sync routine on every
/// connection. Never writes to the thermometer.
final class CoreThermometerClient: NSObject, ThermometerClient {
    let events: AsyncStream<ThermometerEvent>

    private static let restoreIdentifier = "dev.willsawyerrrr.apple-health-multiplexer.central"
    private static let peripheralKey = "thermometerPeripheralID"

    private let continuation: AsyncStream<ThermometerEvent>.Continuation
    private let now: () -> Date
    private let defaults: UserDefaults
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var servicesPending = 0
    private var attributor = ReadingAttributor()
    private var polling = false
    private var liveQueue: [TemperatureMeasurement] = []

    private let temperatureUUID = CBUUID(string: ThermoCare.temperatureMeasurement)
    private let queueUUID = CBUUID(string: ThermoCare.queueHead)
    private let profileUUID = CBUUID(string: ThermoCare.currentProfile)
    private let clockUUID = CBUUID(string: ThermoCare.clock)

    init(now: @escaping () -> Date = Date.init, defaults: UserDefaults = .standard) {
        var continuation: AsyncStream<ThermometerEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
        self.now = now
        self.defaults = defaults
        super.init()
    }

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(
            delegate: self, queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier])
    }

    private func log(_ message: String) { continuation.yield(.log(message)) }
    private func set(_ state: ConnectionState) { continuation.yield(.state(state)) }

    private func connectIfPossible() {
        guard central.state == .poweredOn else { return }
        if peripheral == nil,
            let id = defaults.string(forKey: Self.peripheralKey).flatMap(UUID.init(uuidString:)),
            let known = central.retrievePeripherals(withIdentifiers: [id]).first
        {
            adopt(known)
        }
        guard let peripheral else {
            central.scanForPeripherals(withServices: [CBUUID(string: ThermoCare.healthThermometerService)])
            set(.waiting)
            log("scanning")
            return
        }
        switch peripheral.state {
        case .connected:
            didConnect(peripheral)
        case .connecting:
            set(.connecting)
        default:
            central.connect(peripheral)
            set(.waiting)
            log("pending connect")
        }
    }

    private func adopt(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        defaults.set(peripheral.identifier.uuidString, forKey: Self.peripheralKey)
    }

    private func didConnect(_ peripheral: CBPeripheral) {
        set(.connecting)
        log("connected")
        characteristics = [:]
        liveQueue = []
        polling = false
        peripheral.discoverServices([
            CBUUID(string: ThermoCare.healthThermometerService), CBUUID(string: ThermoCare.currentTimeService),
        ])
    }

    private func startSync(_ peripheral: CBPeripheral) {
        guard let clock = characteristics[clockUUID], characteristics[queueUUID] != nil,
            characteristics[temperatureUUID] != nil, characteristics[profileUUID] != nil
        else {
            log("missing characteristics")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.readValue(for: clock)
    }

    private func pollQueue(_ peripheral: CBPeripheral) {
        guard let queue = characteristics[queueUUID] else { return }
        peripheral.readValue(for: queue)
    }
}

extension CoreThermometerClient: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: connectIfPossible()
        case .unauthorized: set(.unauthorized)
        default: set(.bluetoothOff)
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState state: [String: Any]) {
        guard let restored = (state[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else { return }
        adopt(restored)
        log("restored")
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover discovered: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? discovered.name ?? ""
        guard name.uppercased().contains(ThermoCare.advertisedName) else { return }
        central.stopScan()
        adopt(discovered)
        connectIfPossible()
    }

    func centralManager(_ central: CBCentralManager, didConnect connected: CBPeripheral) {
        didConnect(connected)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral disconnected: CBPeripheral, error: Error?) {
        log("disconnected \(error?.localizedDescription ?? "")")
        polling = false
        connectIfPossible()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect failed: CBPeripheral, error: Error?) {
        log("connect failed \(error?.localizedDescription ?? "")")
        connectIfPossible()
    }
}

extension CoreThermometerClient: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        servicesPending = services.count
        if services.isEmpty { startSync(peripheral) }
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        for characteristic in service.characteristics ?? [] { characteristics[characteristic.uuid] = characteristic }
        servicesPending -= 1
        if servicesPending == 0 { startSync(peripheral) }
    }

    func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
    ) {
        if let error {
            log("subscribe failed \(error.localizedDescription)")
        } else if characteristic.uuid == temperatureUUID, characteristic.isNotifying {
            set(.connected)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        if let error {
            log("error on \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        let data = characteristic.value ?? Data()
        switch characteristic.uuid {
        case clockUUID:
            guard data.count == 4 else { return log("bad clock \(data.hex)") }
            let clock = Double(data.uint32BE(at: 0))
            let offset = now().timeIntervalSince1970.rounded() - clock
            log("clock \(Int(clock)) offset \(Int(offset))s")
            attributor.beginSession(clockOffset: offset)
            polling = true
            pollQueue(peripheral)
            if let temperature = characteristics[temperatureUUID] {
                peripheral.setNotifyValue(true, for: temperature)
            }
        case queueUUID:
            guard let read = QueueRead(data) else {
                polling = false
                return log("bad record \(data.hex)")
            }
            if case .record(let record) = read {
                log("record ts=\(record.timestamp) idx=\(record.index) profile=\(record.profile)")
            }
            if polling, attributor.observe(read) {
                pollQueue(peripheral)
            } else if polling {
                polling = false
                log("queue empty")
            }
        case temperatureUUID:
            guard let measurement = TemperatureMeasurement(data) else { return log("bad indication \(data.hex)") }
            log("indication \(String(format: "%.1f", measurement.celsius)) ts=\(measurement.timestamp)")
            switch attributor.receive(measurement, at: now().timeIntervalSince1970) {
            case .resolved(let reading):
                if let reading { continuation.yield(.reading(reading)) }
            case .needsCurrentProfile:
                liveQueue.append(measurement)
                if let profile = characteristics[profileUUID] { peripheral.readValue(for: profile) }
            }
        case profileUUID:
            guard data.count == 2, !liveQueue.isEmpty else { return log("bad profile \(data.hex)") }
            let measurement = liveQueue.removeFirst()
            let profile = Int(data.uint16BE(at: 0))
            log("live profile \(profile)")
            if let reading = attributor.completeLive(measurement, profile: profile) {
                continuation.yield(.reading(reading))
            }
        default:
            break
        }
    }
}

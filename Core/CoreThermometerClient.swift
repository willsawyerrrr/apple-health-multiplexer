import CoreBluetooth
import Foundation

/// CoreBluetooth implementation of `ThermometerClient`. Keeps a pending
/// connect with state restoration and runs the read-only sync routine on every
/// connection. Its only write is the enabled-slot mask to the profile command characteristic; it never
/// sends the select command or pops the queue.
final class CoreThermometerClient: NSObject, ThermometerClient {
    let events: AsyncStream<ThermometerEvent>

    private static let restoreIdentifier = "dev.willsawyerrrr.kintemp.central"
    private static let peripheralKey = "thermometerPeripheralID"
    private static let pendingSlotsKey = "pendingSlotEdits"

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
    /// The mask just written and the edits it carries, until the read-back resolves them.
    private var inFlight: (mask: EnabledSlotMask, edits: [Int: Bool])?

    private let temperatureUUID = CBUUID(string: ThermoCare.temperatureMeasurement)
    private let queueUUID = CBUUID(string: ThermoCare.queueHead)
    private let profileUUID = CBUUID(string: ThermoCare.currentProfile)
    private let clockUUID = CBUUID(string: ThermoCare.clock)
    private let commandUUID = CBUUID(string: ThermoCare.profileCommand)
    private let enabledSlotsUUID = CBUUID(string: ThermoCare.enabledSlots)

    /// Slot edits awaiting a successful write; a later edit of a slot replaces an earlier one.
    private var pendingEdits: [Int: Bool] {
        get {
            let stored = defaults.dictionary(forKey: Self.pendingSlotsKey) as? [String: Bool] ?? [:]
            return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in Int(key).map { ($0, value) } })
        }
        set { defaults.set(Dictionary(uniqueKeysWithValues: newValue.map { (String($0.key), $0.value) }), forKey: Self.pendingSlotsKey) }
    }

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

    func setSlot(_ slot: Int, enabled: Bool) {
        guard EnabledSlotMask.slotRange.contains(slot), enabled || slot != Profile.guestSlot else { return }
        pendingEdits[slot] = enabled
        log("queued slot \(slot) \(enabled ? "on" : "off")")
        readEnabledSlots()
    }

    private func readEnabledSlots() {
        guard inFlight == nil, let peripheral, peripheral.state == .connected,
            let mask = characteristics[enabledSlotsUUID]
        else { return }
        peripheral.readValue(for: mask)
    }

    /// Writes `read` with the pending edits applied, if there are any, and reads the mask back to verify.
    private func writeEdits(onto read: EnabledSlotMask, _ peripheral: CBPeripheral) {
        let edits = pendingEdits
        guard !edits.isEmpty, inFlight == nil, let command = characteristics[commandUUID] else { return }
        let target = read.applying(edits)
        guard target != read else {
            pendingEdits = [:]
            return
        }
        guard target.isWritable else { return log("mask not writable \(target.hex)") }
        inFlight = (target, edits)
        log("write mask \(target.hex)")
        peripheral.writeValue(target.payload, for: command, type: .withResponse)
    }

    /// Clears the edits `inFlight` carried if the thermometer now holds its mask.
    private func verify(_ read: EnabledSlotMask) {
        guard let (mask, edits) = inFlight else { return }
        inFlight = nil
        guard read == mask else { return log("mask mismatch \(read.hex)") }
        pendingEdits = pendingEdits.filter { edits[$0.key] != $0.value }
        log("mask verified")
        if !pendingEdits.isEmpty { readEnabledSlots() }
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
        inFlight = nil
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

    private func publish(_ update: ReadingAttributor.Update, _ peripheral: CBPeripheral) {
        for reading in update.readings { continuation.yield(.reading(reading)) }
        for measurement in update.needsCurrentProfile {
            liveQueue.append(measurement)
            if let profile = characteristics[profileUUID] { peripheral.readValue(for: profile) }
        }
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
        _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard characteristic.uuid == commandUUID else { return }
        if let error {
            inFlight = nil
            return log("mask write failed \(error.localizedDescription)")
        }
        if let mask = characteristics[enabledSlotsUUID] { peripheral.readValue(for: mask) }
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
            readEnabledSlots()
            if let temperature = characteristics[temperatureUUID] {
                peripheral.setNotifyValue(true, for: temperature)
            }
        case queueUUID:
            guard let read = QueueRead(data) else {
                log("bad record \(data.hex)")
                guard polling else { return }
                polling = false
                return publish(attributor.finishPolling(), peripheral)
            }
            if case .record(let record) = read {
                log("record ts=\(record.timestamp) idx=\(record.index) profile=\(record.profile)")
            }
            guard polling else { return }
            let (keepPolling, update) = attributor.observe(read)
            publish(update, peripheral)
            if keepPolling {
                pollQueue(peripheral)
            } else {
                polling = false
                log("queue empty")
            }
        case enabledSlotsUUID:
            guard let mask = EnabledSlotMask(data) else {
                inFlight = nil
                return log("bad mask \(data.hex)")
            }
            if inFlight != nil { verify(mask) } else { writeEdits(onto: mask, peripheral) }
            continuation.yield(.enabledSlots(mask, pending: pendingEdits))
        case temperatureUUID:
            guard let measurement = TemperatureMeasurement(data) else { return log("bad indication \(data.hex)") }
            log("indication \(String(format: "%.1f", measurement.celsius)) ts=\(measurement.timestamp)")
            publish(attributor.receive(measurement, at: now().timeIntervalSince1970), peripheral)
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

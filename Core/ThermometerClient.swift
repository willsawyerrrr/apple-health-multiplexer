import Foundation

enum ConnectionState: Equatable {
    case bluetoothOff
    case unauthorized
    /// A pending connect is outstanding; the thermometer is not in range or asleep.
    case waiting
    case connecting
    /// Connected and receiving readings.
    case connected
}

enum ThermometerEvent {
    case state(ConnectionState)
    case reading(ThermometerReading)
    /// The mask read from the thermometer, and the slot edits (`true` enables) still waiting to be written.
    case enabledSlots(EnabledSlotMask, pending: [Int: Bool])
    case log(String)
}

protocol ThermometerClient: AnyObject {
    /// Events from the thermometer. Valid after `start()`.
    var events: AsyncStream<ThermometerEvent> { get }
    /// Begins connecting; reconnects after every disconnect.
    func start()
    /// Queues enabling or disabling `slot` in the thermometer's enabled-slot mask. The write waits for a
    /// live connection and is retried on each one until the mask read back matches.
    func setSlot(_ slot: Int, enabled: Bool)
}

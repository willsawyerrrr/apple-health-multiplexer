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
    case log(String)
}

protocol ThermometerClient: AnyObject {
    /// Events from the thermometer. Valid after `start()`.
    var events: AsyncStream<ThermometerEvent> { get }
    /// Begins connecting; reconnects after every disconnect.
    func start()
}

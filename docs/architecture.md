# Architecture

```
CoreThermometerClient (CoreBluetooth) ──events──▶ ReadingsModel ──▶ ReadingsView
        │
        └── ReadingAttributor, TemperatureMeasurement, QueueRead (pure)
```

## Core

- `TemperatureMeasurement` parses a 2A1C packet (Celsius or Fahrenheit, to
  Celsius) into degrees and a thermometer-clock Unix timestamp.
- `QueueRead` parses a 2A75 value into `.empty` or a `ThermometerRecord`.
- `ReadingAttributor` holds the per-connection state: clock offset, the
  timestamp-to-profile map built from polled records, the indications waiting
  for their record, the empty-read streak that ends polling, and the
  cross-connection dedupe set. It takes every input (including times) as
  arguments, so it is deterministic. `receive` and `observe` return an `Update`
  of finalised readings plus lone live indications (`needsCurrentProfile`),
  which the client completes with `completeLive(_:profile:)` after reading
  2A78. An indication is finalised when its record is polled, or when polling
  finishes.
- `ThermometerClient` is the protocol the UI depends on: `start()` and an
  `events` stream of `ThermometerEvent` (`state`, `reading`, `log`).
- `CoreThermometerClient` implements it. It restores state under a fixed
  identifier, remembers the peripheral identifier, scans for the thermometer
  only until it has found it, and otherwise keeps a pending `connect`. On every
  connection it discovers services `1809` and `1805`, reads the clock, starts
  the 2A75 poll loop, and subscribes to 2A1C. It is read-only.

## App

- `ReadingsModel` (`@Observable`) consumes the client's events: connection
  state, readings (newest first) and a bounded debug log.
- `ReadingsView` lists readings (profile or ambiguous, °C, time), the
  connection state, and the debug log of raw records and indications.
- `Info.plist` declares `NSBluetoothAlwaysUsageDescription`, the
  `bluetooth-central` background mode and `ITSAppUsesNonExemptEncryption`
  as `false`.

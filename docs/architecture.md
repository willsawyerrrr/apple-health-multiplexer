# Architecture

```
CoreThermometerClient (CoreBluetooth) ──events──▶ ReadingsModel ──▶ ReadingsView
        │
        └── ReadingAttributor, TemperatureMeasurement, QueueRead (pure)

ReadingsModel ──▶ ReadingSyncCoordinator ──▶ ReadingStore (local outbox)
                                        └──▶ HouseholdSync (CloudKit)
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
  finishes (three empty reads, or a malformed 2A75 value via `finishPolling()`).
- `ThermometerClient` is the protocol the UI depends on: `start()` and an
  `events` stream of `ThermometerEvent` (`state`, `reading`, `log`).
- `CoreThermometerClient` implements it. It restores state under a fixed
  identifier, remembers the peripheral identifier, scans for the thermometer
  only until it has found it, and otherwise keeps a pending `connect`. On every
  connection it discovers services `1809` and `1805`, reads the clock, starts
  the 2A75 poll loop, and subscribes to 2A1C. It is read-only.

- `SyncReading` is an attributed reading with a deterministic record name
  (`reading-<profile>-<whole-second timestamp>-<tenths of a degree>`), so every
  phone derives the same name for the same reading. Unattributed readings have
  no `SyncReading` and are never uploaded.
- `ReadingStore` is durable local storage with an outbox of readings not yet
  uploaded; `FileReadingStore` keeps it in a JSON file written atomically.
- `HouseholdSync` uploads a reading (a duplicate succeeds) and fetches changes
  since the previous fetch. `CloudKitHouseholdSync` stores `Reading` records
  (`profile`, `celsius`, `measuredAt`) in a `Household` zone: the shared
  database's zone when this phone is a member, else a zone it owns in the
  private database, created on demand. A `serverRecordChanged` save counts as
  success. The change token is persisted; an expired token restarts the fetch.
- `ReadingSyncCoordinator` persists each attributed reading on receipt, uploads
  the outbox oldest first (stopping at the first failure), and merges fetched
  household readings into the store.

## App

- `ReadingsModel` (`@Observable`) consumes the client's events: connection
  state, readings (newest first) and a bounded debug log. `delete(_:)` removes
  a reading from the list only; `ReadingAttributor`'s dedupe set keeps a
  re-delivered reading from reappearing.
  It records each reading with the coordinator and runs `syncHousehold()`
  (flush, then pull) whenever the app becomes active.
- `ReadingsView` lists readings (profile or ambiguous, °C, time; swipe to delete), the
  connection state, and the debug log of raw records and indications.
- `Info.plist` declares `NSBluetoothAlwaysUsageDescription`, the
  `bluetooth-central` and `remote-notification` background modes and
  `ITSAppUsesNonExemptEncryption` as `false`. The app's entitlements declare the
  `iCloud.dev.willsawyerrrr.kintemp` CloudKit container.

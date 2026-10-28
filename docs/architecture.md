# Architecture

```
CoreThermometerClient (CoreBluetooth) ──events──▶ ReadingsModel ──▶ ReadingsView
        │                                      │
        │                                      └──▶ HealthSync ──▶ HealthWriter (HealthKit)
        └── ReadingAttributor, TemperatureMeasurement, QueueRead, Profile, ProfileDirectory (pure)

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
- `Profile` is a thermometer slot's record: slot, display name, optional owner
  and ignored flag. Slot 0 is the guest slot. `isTracked` is false for the guest
  slot and ignored profiles: their readings are shown on the phone that read
  them but must never be uploaded or written to Health.
- `ProfileDirectory` holds profiles by slot, resolves display names (default
  `Guest` or `Profile N`; a blank rename restores it) and persists every change
  through a `ProfileStore`. `UserDefaultsProfileStore` is the local store; a
  CloudKit-backed store can implement the protocol.

- `SyncReading` is an attributed reading with a deterministic record name
  (`reading-<profile>-<whole-second timestamp>-<tenths of a degree>`), so every
  phone derives the same name for the same reading; Health uses it as the
  sample's sync identifier, so a reading seen via Bluetooth and CloudKit maps to
  one Health sample. Unattributed readings have
  no `SyncReading` and are never uploaded.
- `ReadingStore` is durable local storage with an outbox of readings not yet
  uploaded; `FileReadingStore` keeps it in a JSON file written atomically.
- `HouseholdSync` uploads a reading (a duplicate succeeds) and fetches changes
  since the previous fetch. `CloudKitHouseholdSync` stores `Reading` records
  (`profile`, `celsius`, `measuredAt`) in a `Household` zone: the shared
  database's zone when this phone is a member, else a zone it owns in the
  private database, created on demand. A `serverRecordChanged` save counts as
  success. The change token is persisted; an expired token restarts the fetch.
- `ReadingSyncCoordinator` persists each attributed reading of a tracked profile on receipt (guest and
  ignored profiles' readings stay off the store and CloudKit), uploads
  the outbox oldest first (stopping at the first failure), and merges fetched
  household readings into the store.
- `HealthWriter` writes a `HealthSample` idempotently and requests write-only
  body temperature access. `HealthKitWriter` saves an `HKQuantitySample`
  (`bodyTemperature`, °C, start and end at the measurement time) with the
  reading's `SyncReading.recordName` as `HKMetadataKeySyncIdentifier` and `HKMetadataKeySyncVersion` 1.
- `HealthSync` holds `myProfile` (0, 1 or 2; local, in `UserDefaults`, not
  synced) and a pending queue persisted in `UserDefaults`. `submit` queues only
  readings for `myProfile` when that profile is tracked, deduplicated by name. `flush` writes the queue in
  order and keeps samples whose write fails (HealthKit cannot be written while
  the phone is locked). `KintempApp` flushes when the scene becomes active and
  when `protectedDataDidBecomeAvailableNotification` fires.

## App

- `ReadingsModel` (`@Observable`) consumes the client's events: connection
  state, readings (newest first) and a bounded debug log. `delete(_:)` removes
  a reading from the list only; `ReadingAttributor`'s dedupe set keeps a
  re-delivered reading from reappearing.
  It passes each reading to `HealthSync`, records it with the coordinator and
  runs `syncHousehold()` (flush, then pull) whenever the app becomes active.
- `ProfileBook` (`@Observable`) wraps `ProfileDirectory` for the UI.
  `ProfilesView` renames profiles (guest slot, stored and observed slots).
- `MyProfilePicker` sets `myProfile`.
- `ReadingsView` lists readings (profile name or ambiguous, °C, time; swipe to delete), the
  connection state, and the debug log of raw records and indications.
- `Info.plist` declares `NSBluetoothAlwaysUsageDescription`, the
  `bluetooth-central` and `remote-notification` background modes,
  `NSHealthUpdateUsageDescription` and `ITSAppUsesNonExemptEncryption` as
  `false`. The app's entitlements enable HealthKit and declare the
  `iCloud.dev.willsawyerrrr.kintemp` CloudKit container.

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
  uploaded; `FileReadingStore` keeps it in a JSON file written atomically,
  along with the record names deleted on this phone; `add` refuses those names.
- `HouseholdSync` uploads a reading (a duplicate succeeds) and fetches changes
  since the previous fetch. `CloudKitHouseholdSync` stores `Reading` records
  (`profile`, `celsius`, `measuredAt`) in a `Household` zone: the shared
  database's zone when this phone is a member, else a zone it owns in the
  private database, created on demand. A `serverRecordChanged` save counts as
  success. The change token is persisted; an expired token restarts the fetch.
- `ReadingSyncCoordinator` persists each attributed reading of a tracked profile on receipt (guest and
  ignored profiles' readings stay off the store and CloudKit), uploads
  the outbox oldest first (stopping at the first failure), and merges fetched
  household readings into the store. `delete` removes a reading from the store
  and outbox and records its record name as deleted, so it is never uploaded,
  stored or shown again.
- `HouseholdSharing` creates the household share and accepts an incoming one.
  `CloudKitHouseholdSharing` uses a zone-wide `CKShare` on the `Household` zone
  (read-write participants, `publicPermission` none, so private by default). It
  reuses the shared database's share when this phone is a member; otherwise it
  creates the zone in the private database if needed, and the share. Accepting
  calls `CKContainer.accept`. `HouseholdInvitations` (`@Observable`) drives the
  flow: `invite()` prepares the share to present, `accept(_:)` joins and then
  runs `onAccepted`, which makes `CloudKitHouseholdSync` forget its cached zone
  and syncs, so it resolves to the shared zone. Failures surface as
  `errorMessage`.
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
  a reading from the list and the store, and drops its unwritten Health sample.
  Deletion is local to this phone: the CloudKit record stays (the household's
  copy is unchanged) and a sample already written to Health stays there.
  Readings deleted here are ignored when they arrive again over Bluetooth or
  CloudKit, and after relaunch.
  It passes each reading to `HealthSync`, records it with the coordinator and
  runs `syncHousehold()` (flush, then pull) whenever the app becomes active.
- `ProfileBook` (`@Observable`) wraps `ProfileDirectory` for the UI.
  `ProfilesView` renames profiles (guest slot, stored and observed slots).
- `ReadingsView`'s "Invite household" toolbar button calls `invite()` and
  presents `CloudSharingView`, a `UICloudSharingController` wrapper offering
  read-write and private-only permissions. `AppDelegate` installs
  `SceneDelegate`, whose `userDidAcceptCloudKitShareWith` (and the launch
  connection options' `cloudKitShareMetadata`) pass the metadata through
  `ShareAcceptance` to `accept(_:)`; metadata arriving before the handler is set
  is queued.
- `MyProfilePicker` sets `myProfile`.
- `ReadingsView` lists readings (profile name or ambiguous, °C, time; swipe to delete), the
  connection state, and the debug log of raw records and indications.
- `Info.plist` declares `NSBluetoothAlwaysUsageDescription`, the
  `bluetooth-central` and `remote-notification` background modes,
  `NSHealthShareUsageDescription` (App Store Connect requires it with the HealthKit entitlement),
  `NSHealthUpdateUsageDescription`, `CKSharingSupported` as `true` and
  `ITSAppUsesNonExemptEncryption` as `false`. The app's entitlements enable HealthKit and declare the
  `iCloud.dev.willsawyerrrr.kintemp` CloudKit container.

## CloudKit schema

`CloudKit/schema.ckdb` defines the `Reading` record type (`profile` INT64,
`celsius` DOUBLE, `measuredAt` TIMESTAMP) in the `iCloud.dev.willsawyerrrr.kintemp`
container. The `Household` zone and its share are created at runtime. Apply it to
the Development environment with the shared Apple Development 1Password
Environment (it supplies `CLOUDKIT_MANAGEMENT_TOKEN` and `DEVELOPMENT_TEAM`):

```sh
op run --environment b5zkkwxuutlttwbrv5xhgojye4 -- sh -c 'xcrun cktool import-schema \
  --token "$CLOUDKIT_MANAGEMENT_TOKEN" --team-id "$DEVELOPMENT_TEAM" \
  --container-id iCloud.dev.willsawyerrrr.kintemp --environment development \
  --validate --file CloudKit/schema.ckdb'
```

`cktool` cannot deploy to Production. After a schema change, click Deploy Schema
Changes in the CloudKit Console.

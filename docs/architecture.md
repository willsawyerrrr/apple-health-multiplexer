# Architecture

```
CoreThermometerClient (CoreBluetooth) ──events──▶ ReadingsModel ──▶ ReadingsView
        │                                      │
        │                                      └──▶ HealthSync ──▶ HealthWriter (HealthKit)
        └── ReadingAttributor, TemperatureMeasurement, QueueRead, Profile, ProfileDirectory (pure)

ReadingsModel ──▶ ReadingSyncCoordinator ──▶ ReadingStore (local outbox)
        │                               └──▶ HouseholdSync (CloudKit)
        └──▶ ProfileSyncCoordinator ──▶ ProfileBook ──▶ ProfileDirectory ──▶ ProfileStore (local)
                                   └──▶ ProfileSync (CloudKit, same zone)
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
  the 2A75 poll loop, and subscribes to 2A1C. Its only write is the enabled-slot
  mask (see `EnabledSlotMask`); it never sends the select command or pops the queue.
  `setSlot(_:enabled:)` records a slot edit in `UserDefaults` (a later edit of a
  slot replaces an earlier one) and, on a live connection, reads 2A79 first. With
  edits pending, the read mask is written with the edits applied (`55 4E 00` + mask
  - `FF FF`, 19 bytes, with response to 2A74) and 2A79 is read back: only a read
    equal to the written mask clears the edits. A write failure, a mismatch, or a
    mask whose first two bytes are `FFFF` (which the thermometer ignores) leaves the
    edits pending for the next connection, which reads 2A79 right after the clock.
    The client emits `.enabledSlots(mask, pending:)` after each 2A79 read.
- `EnabledSlotMask` is the 14-byte enabled-slot mask: `contains`, `slots`,
  `setting(_:enabled:)` (changes one bit, keeps slot 0 enabled and ignores slots
  outside 0-99), `applying(_:)`, `lowestFreeSlot(reserved:)`, `isWritable` (not
  `FFFF` first) and the 19-byte `payload`.
- `Profile` is a thermometer slot's record: slot, display name, optional owner
  and ignored flag, plus sync metadata: `modifiedAt` and `isPendingUpload`. Slot 0 is the guest slot. `isTracked` is false for the guest
  slot and ignored profiles: their readings are shown on the phone that read
  them but must never be uploaded or written to Health.
- `ProfileDirectory` holds profiles by slot, resolves display names (default
  `Guest` or `Profile N`; a blank rename restores it) and persists every change
  through a `ProfileStore` (`UserDefaultsProfileStore` is the local store). A name or
  ignored-flag edit sets `modifiedAt` to now and marks the profile pending upload;
  an unchanged value is not an edit. `apply(_:)` merges a `ProfileChange` from the
  household: the version with the newer `modifiedAt` wins, a household `reset`
  (deleted record) restores the defaults unless an edit is pending, and the local
  `owner` is untouched. `finishUpload(of:result:)` clears the pending flag unless
  the profile was edited meanwhile, and merges the household's version afterwards.
  A profile customised before syncing existed (no `modifiedAt`) is pending, so it
  uploads once and loses to any existing household record.
- `ProfileSync` is the household's profile records: `uploadProfile(_:)` returns the
  household's version after the save, and `takeProfileChanges()` drains the profile
  changes seen by household fetches. `CloudKitHouseholdSync` implements it.

- `SyncReading` is an attributed reading with a deterministic record name
  (`reading-<profile>-<whole-second timestamp>-<tenths of a degree>`), so every
  phone derives the same name for the same reading; Health uses it as the
  sample's sync identifier, so a reading seen via Bluetooth and CloudKit maps to
  one Health sample. Unattributed readings have
  no `SyncReading` and are never uploaded.
- `ReadingStore` is durable local storage with an outbox of readings not yet
  uploaded; `FileReadingStore` keeps it in a JSON file written atomically,
  along with the record names deleted (here or by the household), which `add` refuses, and the queue of
  household copies still to be deleted. `delete` queues a household deletion only for an uploaded
  reading; `discard` removes a reading the household deleted and queues nothing.
- `HouseholdSync` uploads a reading (a duplicate succeeds), deletes the
  household's copy of a reading (one already gone succeeds) and fetches changes
  (`HouseholdChanges`: readings and deleted record names) since the previous fetch. `CloudKitHouseholdSync` stores `Reading` records
  (`profile`, `celsius`, `measuredAt`) in a `Household` zone: the shared
  database's zone when this phone is a member, else a zone it owns in the
  private database, created on demand. A `serverRecordChanged` save counts as
  success. Deleting a reading deletes the `Reading` record with that name in the
  resolved zone (any read-write participant may); `unknownItem` counts as
  success. The change token is persisted; an expired token restarts the fetch.
- `Profile` records (`slot`, `name`, `ignored` 0 or 1) live in the same `Household`
  zone and database as readings, one per slot with the record name `profile-<slot>`,
  so a rename overwrites. `uploadProfile` saves with `ifServerRecordUnchanged`; on
  `serverRecordChanged` it compares the server record's `modificationDate` with the
  profile's `modifiedAt` and either returns the server's version or saves the
  profile over the server record. `fetchChanges` collects `Profile` modifications
  and deletions (as `reset`) and reports deleted `Reading` record IDs from the same zone change fetch, readings and profiles
  sharing one change token, and holds them for `takeProfileChanges()`; it discards
  them when the token expires.
- `ReadingSyncCoordinator` persists each attributed reading of a tracked profile on receipt (guest and
  ignored profiles' readings stay off the store and CloudKit), uploads
  the outbox oldest first (stopping at the first failure), and merges fetched
  household readings into the store. `delete` removes a reading from the store
  and outbox, records its name as deleted and, if it was uploaded, queues the
  deletion of the household's copy. `flush` first carries out queued deletions,
  then uploads, each stopping at the first failure (offline), so both retry on the
  next flush; a flush requested during a flush reruns afterwards. A reading
  deleted while its upload is in flight has its household copy deleted once the
  upload finishes. `pull` discards readings the household deleted, then adds the
  others. The deleted-name set is a guard: queued or in-flight uploads, retries
  and Bluetooth re-delivery cannot bring a deleted reading back.
- `CloudKitSchemaBootstrap` (Debug only) runs `prepareShare` at launch when given `-BootstrapCloudKitSchema`, then exits.
- `HouseholdSubscriptions.ensure` gives the private and shared databases one
  `CKDatabaseSubscription` each (`household-private`, `household-shared`),
  skipping a database whose subscription already exists, so launching repeatedly
  is idempotent; one database failing does not stop the other.
  `CloudKitSubscriptionDatabase` makes them silent
  (`shouldSendContentAvailable`, no alert, sound or badge).
  `KintempApp` calls `CloudKitHouseholdSync.ensureSubscriptions()` at launch.
- `HouseholdSharing` creates the household share and accepts an incoming one.
  `CloudKitHouseholdSharing` uses a zone-wide `CKShare` on the `Household` zone
  (read-write participants, `publicPermission` none, so private by default). It
  reuses the shared database's share when this phone is a member; otherwise it
  creates the zone in the private database if needed, and the share. Accepting
  calls `CKContainer.accept`. `HouseholdInvitations` (`@Observable`) drives the
  flow: `invite()` prepares the share to present, `accept(_:)` joins and then
  runs `onAccepted`, which makes `CloudKitHouseholdSync` forget its cached zone
  and syncs, so it resolves to the shared zone. `prepareShare` first checks
  `CKContainer.accountStatus` (anything but available throws
  `ICloudUnavailableError`) and logs each step. `invite()` runs it under
  `withTimeout` (30 seconds by default, returning even if CloudKit ignores
  cancellation) and sets `isPreparing` while it runs. Failures, including
  timeouts and the sharing sheet's `failedToSaveShareWithError`, surface as
  `errorMessage` carrying the `CKError` code and name, are written to the
  debug log, and set `canRetryInvite`, so the alert offers Retry.
- `HealthWriter` writes a `HealthSample` idempotently, requests write-only
  body temperature access and reports its `writeStatus` (HealthKit hides read
  access, so only write access is reported). `HealthKitWriter` saves an `HKQuantitySample`
  (`bodyTemperature`, °C, start and end at the measurement time) with the
  reading's `SyncReading.recordName` as `HKMetadataKeySyncIdentifier` and `HKMetadataKeySyncVersion` 1.
  Each sample carries a fixed `HKDevice` (THERMOCARE Smart Thermometer, T&R
  Biofab, MT-3000, hardware V1.7, firmware V2.0T, software V1.0), the same
  details the first-party app records, so Health shows the thermometer under
  Device Details even when another household phone wrote the sample.
  `delete(name:)` deletes the samples this app wrote with that sync identifier
  (`HKHealthStore.deleteObjects`); none is success.
- `HealthSync` holds `myProfile` (0, 1 or 2; local, in `UserDefaults`, not
  synced) and a pending queue persisted in `UserDefaults`. `submit` queues only
  readings for `myProfile` when that profile is tracked, deduplicated by name.
  The names of samples successfully written are kept in `UserDefaults`
  (`written`) and never queued again, so a sample deleted in Health is not
  resurrected; `discard` forgets the name.
  `backfill` queues every reading in `storedReadings` (the model's readings,
  which exclude deleted ones) the same way; it runs when `myProfile` changes to
  a value and when `ReadingsModel` is created, so readings that arrived before
  the profile was chosen are still written.
  `requestAccess` asks Health for write access once `myProfile` is set (when it
  changes to a value, and on each launch and activation), independent of pending
  samples, and only while the status is undetermined; concurrent calls share one
  request. It sets `accessProblem` to a Settings hint when write access is
  denied, or to the error when the request fails. `flush` requests access, then writes the queue in
  order and keeps samples whose write fails (HealthKit cannot be written while
  the phone is locked). `KintempApp` flushes when the scene becomes active and
  when `protectedDataDidBecomeAvailableNotification` fires. `remove(recordNames:)`
  drops unwritten samples and queues Health deletions (persisted in
  `UserDefaults`); `flush` writes first, then deletes, keeping failures (locked
  phone) for retry. When write access is not authorized, queued deletions are
  dropped quietly.

## App

- `ReadingsModel` (`@Observable`) consumes the client's events: connection
  state, readings (newest first) and a bounded debug log. `delete(_:)` removes
  a reading from the list and the store, queues the deletion of its CloudKit
  record (the household's copy, for every member) and of its Health sample, and
  drops an unwritten Health sample. Deletion is permanent and household-wide.
  Readings deleted here or by the household are ignored when they arrive again
  over Bluetooth or CloudKit, and after relaunch.
  It passes each reading to `HealthSync`, records it with the coordinator and
  runs `syncHousehold()` (pull, then flush) whenever the app becomes active. A
  pulled deletion removes the reading from the list and queues its Health
  deletion. Pulling first lets a deletion remove a reading still in the outbox.
- `AppDelegate` calls `registerForRemoteNotifications()` at launch. On a
  `CKDatabaseNotification` silent push, `didReceiveRemoteNotification` runs
  `RemoteChanges`, which `KintempApp` sets at launch (so a background launch can
  answer it) to `model.syncHousehold()`. That pulls with the change token
  (removing readings the household deleted), flushes, feeds new readings to the
  model and `HealthSync`, and returns a `SyncOutcome` (`newData`, `noData`,
  `failed`; a deletion counts as new data) that becomes the
  `UIBackgroundFetchResult`.
- `ProfileBook` (`@Observable`) wraps `ProfileDirectory` for the UI and calls `onChange`
  after each local edit. `ProfilesView` lists and renames profiles for every thermometer slot
  (0, 1, 2), stored profiles and observed slots, and shows names renamed on another phone.
- `ProfileSyncCoordinator` uploads pending profiles (on each edit and in every
  `syncHousehold()`), stopping at the first failure, and merges household changes
  into the `ProfileBook` after the readings pull. A failed upload (offline, or
  Production's schema lacking `Profile`) is written to the debug log, never shown as
  an alert, and retried on the next sync; names keep working locally meanwhile.
  `ReadingsModel.syncHousehold()` runs it, so push-triggered fetches carry profile
  changes too, and reports `newData` when only profiles changed.
- `ReadingsView`'s "Invite household" toolbar button calls `invite()` (a
  spinner replaces it while preparing) and presents `CloudSharingView`, a
  `UICloudSharingController` wrapper offering
  read-write and private-only permissions. `AppDelegate` installs
  `SceneDelegate`, whose `userDidAcceptCloudKitShareWith` (and the launch
  connection options' `cloudKitShareMetadata`) pass the metadata through
  `ShareAcceptance` to `accept(_:)`; metadata arriving before the handler is set
  is queued.
- `ReadingsModel` keeps the last mask read and the pending slot edits.
  `ProfilesView` lists the slots of that mask with pending edits applied (before the
  first read it lists the stored and observed slots and cannot add or remove).
  "Add Person" names the lowest slot that is neither enabled nor reserved (a stored
  profile or a reading exists for it, so a removed person's slot is never reused),
  renames that profile and queues the enable. Swipe-to-remove (not for the guest)
  queues the disable after a confirmation that says the person's readings, name and
  Apple Health data are kept: removal only edits the thermometer's mask, so the
  household's `Profile` records, stored readings and Health samples are untouched.
  The app never selects the active profile.
- `MyProfilePicker` sets `myProfile` (local, never synced), labelling each slot with its profile name, and shows `accessProblem` beneath it.
- `ReadingsView` lists readings (profile name or ambiguous, °C, time; swipe to delete,
  confirmed by a destructive dialog saying it deletes the reading for everyone in the
  household and from Apple Health), the
  connection state, and the debug log of raw records and indications.
- `Info.plist` declares `NSBluetoothAlwaysUsageDescription`, the
  `bluetooth-central` and `remote-notification` background modes,
  `NSHealthShareUsageDescription` (App Store Connect requires it with the HealthKit entitlement),
  `NSHealthUpdateUsageDescription`, `CKSharingSupported` as `true` and
  `ITSAppUsesNonExemptEncryption` as `false`. The app's entitlements enable HealthKit, set `aps-environment` to
  `development` (distribution signing replaces it with `production`; the App ID
  needs the Push Notifications capability) and declare the
  `iCloud.dev.willsawyerrrr.kintemp` CloudKit container.

## CloudKit schema

`CloudKit/schema.ckdb` mirrors the Development environment of the
`iCloud.dev.willsawyerrrr.kintemp` container. It defines the `Reading` record
type (`profile` INT64, `celsius` DOUBLE, `measuredAt` TIMESTAMP), the `Profile` record
type (`slot` INT64, `name` STRING, `ignored` INT64) and the system
types `Users` and `cloudkit.share`. The `Household` zone and its share are
created at runtime.

Sharing needs `cloudkit.share` in the schema. Development creates it just in
time the first time a share is saved, and the committed file carries it exactly
as exported; Production (which TestFlight uses) rejects the save with "Cannot create new type
cloudkit.share in production schema" unless it was deployed from Development.
The alert explains this error in plain language alongside the `CKError` text.

`scripts/bootstrap-cloudkit-schema.sh [simulator name]` creates such types
without a device or a tap. It builds a Debug build for an iPhone Simulator
(ad-hoc signed, so the iCloud entitlement applies), installs it and launches it
with `-BootstrapCloudKitSchema`. That argument exists only in Debug builds
(`CloudKitSchemaBootstrap`): the app runs `CloudKitHouseholdSharing.prepareShare`,
the path the Invite button takes, prints `bootstrap: OK` or `bootstrap: FAILED, ...`
and exits (0 success, 2 no iCloud account, 1 any other failure). On success the
script exports the Development schema to `build/development-schema.ckdb` via
`cktool` and the shared Apple Development 1Password Environment. The Simulator
needs an iCloud account (Settings, Apple Account). Run the script again after a
schema change that adds system types, then deploy.

`Reading` and `Profile` grant no roles. The app reads and writes only the private and shared
databases, where access comes from zone ownership and the `CKShare`; record-type
grants govern only the public database, which the app never uses. `Users` and
`cloudkit.share` are system types and keep their system-assigned grants, which
likewise apply only to the public database.

Apply it to
the Development environment with the shared Apple Development 1Password
Environment (it supplies `CLOUDKIT_MANAGEMENT_TOKEN` and `DEVELOPMENT_TEAM`):

```sh
op run --environment b5zkkwxuutlttwbrv5xhgojye4 -- sh -c 'xcrun cktool import-schema \
  --token "$CLOUDKIT_MANAGEMENT_TOKEN" --team-id "$DEVELOPMENT_TEAM" \
  --container-id iCloud.dev.willsawyerrrr.kintemp --environment development \
  --validate --file CloudKit/schema.ckdb'
```

`cktool` cannot deploy to Production, and only Development to Production is
possible. After a schema change, click Deploy Schema Changes in the CloudKit
Console. Until `Profile` is deployed, saving profiles fails in Production and
the app retries them quietly.

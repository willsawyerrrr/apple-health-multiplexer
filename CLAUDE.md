# CLAUDE.md

## Repo purpose

An iOS app (SwiftUI, XcodeGen) that connects to a ThermoCare Bluetooth
thermometer and emits temperature readings attributed to a thermometer profile.
HealthKit and CloudKit are out of scope for the Bluetooth layer.

## Layout

- `project.yml` — XcodeGen project; `Kintemp` app and
  `KintempTests` targets. The `.xcodeproj` is not committed.
- `Core/` — framework-free parsers and `ReadingAttributor` (pairing, clock
  offset, filter, dedupe), the `ThermometerClient` protocol, and the
  CoreBluetooth `CoreThermometerClient`.
- `App/` — SwiftUI app, `ReadingsModel`, `ReadingsView`, `Info.plist`.
- `Tests/` — Swift Testing suites with real captured fixtures.
- `docs/protocol.md` — the thermometer's GATT protocol and sync routine.
  `docs/architecture.md` — code structure.

## Rules

- Never write to any thermometer characteristic: popping records via the
  queue-pop characteristic also deletes the readings.
- A change to the protocol or routine updates `docs/protocol.md` and
  `docs/architecture.md` in the same PR.
- Bundle ID is `dev.willsawyerrrr.kintemp`.
  `DEVELOPMENT_TEAM` comes from the shared Apple Development 1Password
  Environment; locally run
  `op run --environment b5zkkwxuutlttwbrv5xhgojye4 -- xcodegen generate`.

## Commands

- Tests: `DEVELOPMENT_TEAM= xcodegen generate`, then
  `xcodebuild test -scheme Kintemp -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO`.
- CI (`.github/workflows/ci.yml`) runs `pre-commit` and `ios` on `macos-26`
  with Xcode 26.6 (also in `.xcode-version`; bump together). The aggregate
  `CI Status` job `needs` every other job; add new jobs to it. `main`'s
  ruleset requires only `CI Status`.

## Conventions

Standard [willsawyerrrr.dev conventions](../../CLAUDE.md) apply.

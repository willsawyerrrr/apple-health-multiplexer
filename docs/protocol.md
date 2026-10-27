# ThermoCare protocol

## Device

- Advertises as `THERMOCARE` (services `180A`, `180F`, `1805`, `1809`),
  connectable.
- Drops the connection about a minute after the last activity and when a
  measurement starts, then re-advertises. The app keeps a pending `connect`
  with CoreBluetooth state restoration and runs the whole routine on every
  connection.

## UUIDs

Custom UUIDs use the base `0000xxxx-0000-2000-4200-D3E2ADFBE7EF`.

| Service | Characteristic | Use                                                                                               |
| ------- | -------------- | ------------------------------------------------------------------------------------------------- |
| `1809`  | `2A1C`         | Standard Temperature Measurement (indicate)                                                       |
| `1809`  | `2A75`         | 20-byte head-of-queue record (read)                                                               |
| `1809`  | `2A78`         | Current profile, `UInt16` big-endian: `0001` profile 1, `0002` profile 2, `0000` profile 0 (read) |
| `1809`  | `2A81`         | Queue count                                                                                       |
| `1805`  | `2A2C`         | Thermometer clock, 4 bytes, Unix seconds big-endian                                               |

Profile 0 is not stored by the first-party app.

## Packets

### 2A1C

Flags byte (`06` = Celsius, timestamp present, type present; bit 0 set means
Fahrenheit, converted to Celsius), a 4-byte IEEE-11073 FLOAT (3-byte
little-endian signed mantissa, signed exponent byte; `6D 01 00 FF` = 36.5), a
7-byte timestamp (`UInt16` LE year, month, day, hour, minute, second), and a
type byte (`02`).

The timestamp is the thermometer clock in UTC. It is minutes off real time and
drifts between sessions. Example: `066D0100FFEA070A1B0E1D2B02` = 36.5 °C at
2026-10-27 14:29:43 thermometer time.

### 2A75

Read as 20 bytes:

- bytes 0-3: Unix seconds (big-endian) of the measurement on the thermometer
  clock
- bytes 4-5: record index
- bytes 16-17: profile of the record (`UInt16` big-endian)
- all zero bytes: queue empty

Example: `6AE0D60F000710790D68000089FF6CBC00020900` = timestamp 1793119759, index 7,
profile 2.

The 2A1C timestamp converted to Unix seconds in UTC equals the record's bytes
0-3 for the same reading.

## Queue behaviour

The thermometer keeps unsent readings. Subscribing to 2A1C flushes them as
indications, newest first, about 150 ms apart, and removes each record from
2A75 as it sends the matching indication. The head of 2A75 is always the newest
not-yet-sent record.

Per-reading profile is therefore captured by reading 2A75 continuously (one
outstanding read at a time, back to back, about 90 ms round trip) from before
subscribing until it has read empty three times in a row, pairing indications
with records by timestamp equality. One read per indication misses records.

The app never writes to any characteristic: popping records through the queue
pop characteristic would also delete the 2A1C readings.

## Per-connection routine

1. Read 2A2C and compute `clockOffset = hostUnixNow - thermometerClock`.
2. Start the continuous 2A75 poll loop.
3. Subscribe (indicate) to 2A1C. The subscription stays for the whole
   connection.
4. For each indication, parse temperature and timestamp, then look up its
   profile in the polled records by timestamp.
5. If no record was seen and no other indication arrived within the previous
   1 s (a lone live reading), read 2A78 immediately and use that profile.
   Otherwise the profile is `nil`: ambiguous, skipped downstream.
6. `measuredAt = Date(unix: thermometerTimestamp + clockOffset)`.
7. Drop anything outside 32.0-43.0 °C (non-body readings of 22-27 °C appear).
8. Deduplicate on (profile, `measuredAt` to the second, °C).

Indications outside the body range still count toward batch detection.

## Fixtures

Captured readings used by the tests (thermometer Unix timestamp, °C, profile):

| Timestamp  | °C   | Profile      |
| ---------- | ---- | ------------ |
| 1793119732 | 36.1 | 2            |
| 1793119737 | 36.4 | 1            |
| 1793119741 | 36.2 | 1            |
| 1793119743 | 35.9 | 2            |
| 1793119749 | 36.0 | 1            |
| 1793119752 | 26.8 | 2 (filtered) |
| 1793119759 | 35.6 | 2            |

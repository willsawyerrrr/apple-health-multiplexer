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

## Profile select and enabled-slot mask

Observed in PacketLogger captures of the first-party app and verified by
writing to the thermometer from a standalone test script. Kintemp sends only
the mask write, never the select. Profile names, genders, birth dates and the cap of 10 profiles
live in the first-party app, not on the thermometer, whose display never shows
a profile (name or number, whichever is selected): adding a profile writes
nothing to it until it is selected.

Both writes are ATT Write Requests (with response) to the profile command
characteristic `2A74`, handle `0x23`. The first-party app sends them in this
order when a profile is selected, each twice a few hundred ms apart:

| Write                               | Meaning                       |
| ----------------------------------- | ----------------------------- |
| `55 4E 00` + 14-byte mask + `FF FF` | Enabled-slot mask (19 bytes)  |
| `55 00 PP FF FF`                    | Select profile `PP` (5 bytes) |

### Select

`PP` is one byte. Verified:

- The select needs no mask write before it.
- `2A78` reads back the selected profile immediately (`0002` after selecting
  2, `00FF` after selecting 255).
- The next measurement's `2A75` record carries that profile in bytes 16-17
  (selecting 2, 1, 9, 12 and 255 stamped `0002`, `0001`, `0009`, `000C` and
  `00FF`).
- The selection persists after the thermometer drops the connection when a
  measurement starts.
- Any value 0-255 is accepted: the thermometer does not validate against the
  mask or the first-party app's 10-profile cap.

### Enabled-slot mask

The mask is the list of profiles the thermometer steps through when cycling
with its button, and the 14-byte value after `55 4E 00` in the write. `2A79`
reads it back (14 bytes) and reflects a write immediately. Over Bluetooth it has
no effect on selecting or stamping readings.

It is seven 16-bit big-endian words, word `w` covering slots `16w` to
`16w + 15`. Within a word, slot `j` (0-15) is bit `(7 - j) mod 16`: slots 0-7
take bits 7 down to 0 and slots 8-15 take bits 15 down to 8. Verified by
cycling on the thermometer:

| Mask (14 bytes)                      | Cycles through            |
| ------------------------------------ | ------------------------- |
| `E0FF 0000 0000 0000 0000 0000 0000` | 0-10                      |
| `E0FF FF00 …`                        | 0-10, 24-31               |
| `E0FF 00FF 0000 0000 0000 0000 FF00` | 0-10, 16-23               |
| `E0FF 0000 00FF FF00 0000 00FF 0000` | 0-10, 32-39, 56-63, 80-87 |
| `E0FF 0000 0000 0000 0000 FF00 00FF` | 0-10, 88-99               |

Only slots 0-99 exist: the last bits of word 6 (slots 100-111) and the whole
top byte of it have no effect. The cap is 100 profiles, ten times the
first-party app's.

Other behaviour:

- A mask whose first two bytes are `FFFF` (including all `FF`) is silently
  ignored; the write succeeds and `2A79` is unchanged. Every other value
  tested was stored, including `FEFF`, `FFFE` and a full `FFFF` word elsewhere.
- A write that is not 19 bytes is silently ignored.
- Slot 0 (the guest slot) is set in every mask the first-party app wrote.

Adding a profile sets its bit; removing one clears it (`0x00F0` to `0x00E0`
when slot 3 was removed, as `00F0` and `00E0` in the first word).

### Other writes

The first-party app also writes `54 FF FF` to `2A74` before the mask, and on
each connection writes `02 00` to handles `0x0F` and `0x13`, `31 31 31 31` to
`0x4E`, and the current Unix time (4 bytes, big-endian) to `0x5C`, which is
probably a clock sync. Their purposes are unverified, and none are needed to
select a profile.

## Per-connection routine

1. Read 2A2C and compute `clockOffset = hostUnixNow - thermometerClock`.
2. Start the continuous 2A75 poll loop.
3. Subscribe (indicate) to 2A1C. The subscription stays for the whole
   connection.
4. For each indication, parse temperature and timestamp and hold it until a
   polled record with an equal timestamp arrives (the poll trails the
   indications, so the record usually arrives after its indication), then
   finalise it with that record's profile. Profile 0 is a real profile; only
   `nil` is ambiguous. Late or duplicate records for a finalised reading are
   ignored.
5. When polling finishes (three consecutive empty reads, or a malformed 2A75
   value, which is logged and ends polling), finalise every
   indication still unmatched. If it was the only indication in its burst (no
   other indication within 1 s), read 2A78 immediately and use that profile (a
   live single reading). Otherwise the profile is `nil`: ambiguous, skipped
   downstream. After polling has finished, a live indication with no record is
   finalised on arrival the same way.
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

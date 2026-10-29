import Foundation

/// The thermometer's enabled-slot mask: the profiles it steps through when cycling. Seven 16-bit
/// big-endian words; word `w` covers slots `16w` to `16w + 15`, and slot `j` of a word is bit `(7 - j) mod 16`.
struct EnabledSlotMask: Equatable {
    static let byteCount = 14
    /// Slots 0-99 exist; the rest of the mask has no effect.
    static let slotRange = 0..<100

    private(set) var bytes: [UInt8]

    init?(_ data: Data) {
        guard data.count == Self.byteCount else { return nil }
        bytes = Array(data)
    }

    /// Whether `slot` is enabled.
    func contains(_ slot: Int) -> Bool {
        guard let (index, bit) = Self.position(of: slot) else { return false }
        return bytes[index] & bit != 0
    }

    /// The enabled slots, ascending.
    var slots: [Int] { Self.slotRange.filter(contains) }

    /// This mask with `slot` enabled or disabled and every other bit preserved. The guest slot stays
    /// enabled, and a slot outside 0-99 changes nothing.
    func setting(_ slot: Int, enabled: Bool) -> EnabledSlotMask {
        guard let (index, bit) = Self.position(of: slot), enabled || slot != Profile.guestSlot else { return self }
        var copy = self
        if enabled { copy.bytes[index] |= bit } else { copy.bytes[index] &= ~bit }
        return copy
    }

    /// This mask with each edit applied: `true` enables the slot, `false` disables it.
    func applying(_ edits: [Int: Bool]) -> EnabledSlotMask {
        edits.sorted { $0.key < $1.key }.reduce(self) { $0.setting($1.key, enabled: $1.value) }
    }

    /// The lowest slot neither enabled nor in `reserved`, or `nil` when all 100 are taken.
    func lowestFreeSlot(reserved: Set<Int> = []) -> Int? {
        Self.slotRange.first { !contains($0) && !reserved.contains($0) }
    }

    /// The thermometer silently ignores a mask whose first two bytes are `FFFF`.
    var isWritable: Bool { !(bytes[0] == 0xFF && bytes[1] == 0xFF) }

    var hex: String { Data(bytes).hex }

    /// The 19-byte value for the profile command characteristic: `55 4E 00`, the mask, `FF FF`.
    var payload: Data { Data([0x55, 0x4E, 0x00] + bytes + [0xFF, 0xFF]) }

    private static func position(of slot: Int) -> (index: Int, bit: UInt8)? {
        guard slotRange.contains(slot) else { return nil }
        let word = slot / 16
        let bit = (7 - slot % 16 + 16) % 16
        return (word * 2 + (bit >= 8 ? 0 : 1), UInt8(1 << (bit % 8)))
    }
}

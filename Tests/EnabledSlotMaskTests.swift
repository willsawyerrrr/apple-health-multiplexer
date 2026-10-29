import Foundation
import Testing

@testable import Kintemp

struct EnabledSlotMaskTests {
    private func mask(_ hex: String) -> EnabledSlotMask { EnabledSlotMask(Data(hex: hex))! }

    private let firstParty = "E0FF 0000 0000 0000 0000 0000 0000"

    @Test func readsVerifiedLayouts() {
        #expect(mask(firstParty).slots == Array(0...10))
        #expect(mask("E0FF FF00 0000 0000 0000 0000 0000").slots == Array(0...10) + Array(24...31))
        #expect(mask("E0FF 00FF 0000 0000 0000 0000 FF00").slots == Array(0...10) + Array(16...23))
        #expect(mask("E0FF 0000 0000 0000 0000 FF00 00FF").slots == Array(0...10) + Array(88...99))
    }

    @Test func rejectsWrongLength() {
        #expect(EnabledSlotMask(Data(count: 13)) == nil)
        #expect(EnabledSlotMask(Data(count: 15)) == nil)
    }

    @Test func settingASlotChangesOnlyItsBit() {
        let base = mask(firstParty)
        #expect(base.setting(11, enabled: true) == mask("F0FF 0000 0000 0000 0000 0000 0000"))
        #expect(base.setting(16, enabled: true) == mask("E0FF 0080 0000 0000 0000 0000 0000"))
        #expect(base.setting(99, enabled: true) == mask("E0FF 0000 0000 0000 0000 0000 0010"))
        #expect(base.setting(3, enabled: false).slots == [0, 1, 2, 4, 5, 6, 7, 8, 9, 10])
    }

    @Test func preservesOtherBits() {
        let base = mask("E0FF 00FF 0000 0000 0000 0000 FF00")
        let added = base.setting(40, enabled: true)
        #expect(added.slots == (base.slots + [40]).sorted())
        #expect(added.setting(40, enabled: false) == base)
    }

    @Test func guestSlotStaysEnabled() {
        #expect(mask(firstParty).setting(0, enabled: false).contains(0))
    }

    @Test func ignoresSlotsOutsideRange() {
        let base = mask(firstParty)
        #expect(base.setting(100, enabled: true) == base)
        #expect(base.setting(-1, enabled: true) == base)
        #expect(!base.contains(100))
    }

    @Test func lowestFreeSlotSkipsEnabledAndReserved() {
        #expect(mask(firstParty).lowestFreeSlot() == 11)
        #expect(mask(firstParty).lowestFreeSlot(reserved: [11, 12]) == 13)
        #expect(mask(firstParty).setting(11, enabled: true).lowestFreeSlot() == 12)
    }

    @Test func noFreeSlotWhenAllTaken() {
        #expect(mask(firstParty).lowestFreeSlot(reserved: Set(11..<100)) == nil)
    }

    @Test func appliesEdits() {
        let edited = mask(firstParty).applying([12: true, 1: false, 0: false])
        #expect(edited.contains(12) && !edited.contains(1) && edited.contains(0))
    }

    @Test func fullFirstWordIsNotWritable() {
        #expect(!mask("FFFF 0000 0000 0000 0000 0000 0000").isWritable)
        #expect(!mask("FFFF FFFF FFFF FFFF FFFF FFFF FFFF").isWritable)
        #expect(mask("FEFF 0000 0000 0000 0000 0000 0000").isWritable)
        #expect(mask("E0FF FFFF 0000 0000 0000 0000 0000").isWritable)
    }

    @Test func payloadIs19Bytes() {
        let payload = mask(firstParty).payload
        #expect(payload.count == 19)
        #expect(payload == Data(hex: "554E00 E0FF 0000 0000 0000 0000 0000 0000 FFFF"))
    }
}

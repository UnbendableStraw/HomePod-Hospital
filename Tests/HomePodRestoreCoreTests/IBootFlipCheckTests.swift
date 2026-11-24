import XCTest
@testable import HomePodRestoreCore

/// The scripted patch that takes the upside-down check out of Apple's second
/// boot stage. The images here are made up: a few ARM64 instructions with the
/// shape the patch looks for, in padding. With HOMEPOD_IBEC_DEC set to a real
/// decrypted second stage (never in the repository), the last test runs on that.
final class IBootFlipCheckTests: XCTestCase {
    private func words(_ w: [UInt32]) -> Data {
        var d = Data()
        for x in w { d.append(contentsOf: [UInt8(x & 0xFF), UInt8((x >> 8) & 0xFF), UInt8((x >> 16) & 0xFF), UInt8((x >> 24) & 0xFF)]) }
        return d
    }
    private func word(_ d: Data, at offset: Int) -> UInt32 {
        let b = [UInt8](d)
        return UInt32(b[offset]) | UInt32(b[offset + 1]) << 8 | UInt32(b[offset + 2]) << 16 | UInt32(b[offset + 3]) << 24
    }

    /// What the compiler makes of "put 21 01 00 00 5A 84 on the stack and send it".
    private let request: [UInt32] = [
        0x5280_2428,   // mov  w8, #0x121
        0x7800_E3E8,   // stur w8, [sp, #0xe]
        0x5290_8B48,   // mov  w8, #0x845a
        0x7900_27E8,   // strh w8, [sp, #0x12]
        0x9100_3BE2,   // add  x2, sp, #0xe
        0x5280_0060,   // mov  w0, #3
        0x5280_1561,   // mov  w1, #0xab
        0x5280_00C3,   // mov  w3, #6
        0x9400_2C27,   // bl   <send>
        0xF940_0FE8,   // ldr  x8, [sp, #0x18]
    ]
    private let filler: [UInt32] = Array(repeating: 0xAA00_03E0, count: 50)      // mov x0, x0

    func testRemovesTheOneCall() {
        var image = words(filler + request + filler)
        let callAt = (filler.count + 8) * 4
        XCTAssertEqual(IBootFlipCheck.isPresent(in: image), true)
        XCTAssertEqual(IBootFlipCheck.remove(from: &image), .removed(offset: callAt))
        XCTAssertEqual(word(image, at: callAt), 0xD503_201F, "the call is a no-op now")
        // nothing else changed
        var expected = filler + request + filler
        expected[filler.count + 8] = 0xD503_201F
        XCTAssertEqual(image, words(expected))
        XCTAssertEqual(IBootFlipCheck.isPresent(in: image), false)
        // a second run changes nothing and says so
        let before = image
        XCTAssertEqual(IBootFlipCheck.remove(from: &image), .alreadyRemoved(offset: callAt))
        XCTAssertEqual(image, before)
    }

    func testOtherRegistersAndSpacing() {
        // other registers for the constants, an extra instruction in between
        var other = request
        other[0] = 0x5280_2429          // mov w9, #0x121
        other[2] = 0x5290_8B4A          // mov w10, #0x845a
        other.insert(0xD503_201F, at: 1)
        var image = words(filler + other + filler)
        XCTAssertEqual(IBootFlipCheck.remove(from: &image), .removed(offset: (filler.count + 9) * 4))
    }

    func testLeavesOtherCodeAlone() {
        // no such code at all
        var plain = words(filler + filler)
        XCTAssertEqual(IBootFlipCheck.remove(from: &plain), .notFound)
        XCTAssertNil(IBootFlipCheck.isPresent(in: plain))
        // the first constant alone, or the two too far apart, is not the place
        var apart = words(filler + [request[0]] + filler + [request[2], request[8]] + filler)
        let untouched = apart
        XCTAssertEqual(IBootFlipCheck.remove(from: &apart), .notFound)
        XCTAssertEqual(apart, untouched)
        // twice in one image: ambiguous, nothing is changed
        var twice = words(filler + request + filler + request + filler)
        let same = twice
        XCTAssertEqual(IBootFlipCheck.remove(from: &twice), .ambiguous(count: 2))
        XCTAssertEqual(twice, same)
        // too short to hold anything
        var tiny = Data([0x28, 0x24])
        XCTAssertEqual(IBootFlipCheck.remove(from: &tiny), .notFound)
        var empty = Data()
        XCTAssertEqual(IBootFlipCheck.remove(from: &empty), .notFound)
    }

    func testWorksOnASliceAndInsideAWrappedFile() {
        // a Data whose startIndex is not 0
        let whole = words(filler + request + filler)
        var slice = whole.dropFirst(8)
        XCTAssertEqual(IBootFlipCheck.remove(from: &slice), .removed(offset: (filler.count + 8) * 4 - 8))
        XCTAssertEqual(word(Data(slice), at: (filler.count + 8) * 4 - 8), 0xD503_201F)
        // wrapped as IMG4 the code starts at an odd offset: isPresent still finds it
        let raw = words(filler + request + filler)
        let wrapped = IMG4Wrap.wrap(payload: raw, fourcc: "ibec", im4m: Data([0x30, 0x03, 0x02, 0x01, 0x00]))
        XCTAssertEqual(IBootFlipCheck.isPresent(in: wrapped), true)
        var patched = raw
        IBootFlipCheck.remove(from: &patched)
        XCTAssertEqual(IBootFlipCheck.isPresent(in: IMG4Wrap.wrap(payload: patched, fourcc: "ibec", im4m: Data([0x30, 0x03, 0x02, 0x01, 0x00]))), false)
    }

    func testFileOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flipcheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("iBEC.img4")
        XCTAssertNil(IBootFlipCheck.isPresent(inFileAt: file), "no file, no answer")
        let raw = words(filler + request + filler)
        let ticket = Data([0x30, 0x03, 0x02, 0x01, 0x00])
        try IMG4Wrap.wrap(payload: raw, fourcc: "ibec", im4m: ticket).write(to: file)
        XCTAssertEqual(IBootFlipCheck.isPresent(inFileAt: file), true)
        XCTAssertEqual(IBootFlipCheck.isPresent(inFileAt: file), true, "asked again: the remembered answer")
        // rebuilt with the check out (a different size, so the change is seen whatever the clock does)
        var patched = raw + words([0xAA00_03E0])
        IBootFlipCheck.remove(from: &patched)
        try IMG4Wrap.wrap(payload: patched, fourcc: "ibec", im4m: ticket).write(to: file)
        XCTAssertEqual(IBootFlipCheck.isPresent(inFileAt: file), false)
        try Data("not a boot loader".utf8).write(to: file)
        XCTAssertNil(IBootFlipCheck.isPresent(inFileAt: file))
    }

    func testLogLines() {
        XCTAssertEqual(IBootFlipCheck.describe(.removed(offset: 0x1528C)), "Upside-down check taken out of the second stage (the call at 0x1528c).")
        XCTAssertTrue(IBootFlipCheck.describe(.notFound).contains("right-side up"))
        XCTAssertTrue(IBootFlipCheck.describe(.ambiguous(count: 2)).contains("nothing was changed"))
    }

    /// Apple's own file, if one is at hand: HOMEPOD_IBEC_DEC=/path/to/decrypted-iBEC swift test
    func testOnARealSecondStage() throws {
        guard let path = ProcessInfo.processInfo.environment["HOMEPOD_IBEC_DEC"], !path.isEmpty else {
            throw XCTSkip("set HOMEPOD_IBEC_DEC to a decrypted second stage to run this")
        }
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        var image = original
        let outcome = IBootFlipCheck.remove(from: &image)
        guard case .removed(let offset) = outcome else { return XCTFail("expected one place, got \(outcome)") }
        print("real second stage: \(original.count) bytes, call at 0x\(String(offset, radix: 16))")
        XCTAssertEqual(image.count, original.count)
        let changed = zip(original, image).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        XCTAssertEqual(changed.min().map { $0 / 4 * 4 }, offset)
        XCTAssertLessThanOrEqual(changed.count, 4, "four bytes at most")
        XCTAssertEqual(word(image, at: offset), 0xD503_201F)
        XCTAssertEqual(word(original, at: offset) & 0xFC00_0000, 0x9400_0000, "it was a call")
    }
}

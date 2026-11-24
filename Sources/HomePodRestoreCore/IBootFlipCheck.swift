import Foundation

/// Takes the upside-down check out of Apple's second boot stage (iBEC / iBoot).
///
/// A HomePod gets into the chip's own DFU by being powered up upside down.
/// The boot ROM has nothing to do with that: it is Apple's second boot stage
/// that reads the accelerometer, and when it finds the pod upside down for a
/// second it sends one message to the top-panel MCU, which then forces the
/// chip into DFU. The second stage the app sends to boot Nicotine is Apple's
/// too, so it makes the same check: a pod that is still upside down when
/// Nicotine is booted goes straight back to DFU.
///
/// Nothing of Apple's is stored for this. The app downloads the boot loader
/// from Apple and decrypts it on the user's own pod (ReleaseIBootBuilder);
/// this finds the place in that file by its shape and changes four bytes: the
/// call that sends the message becomes a no-op. The sampling before it stays
/// as it is, so does everything else.
///
/// How the place is found: the message is six bytes, `21 01 00 00 5A 84`
/// (command 0x21, one data byte 0x5A, checksum), which the code builds on the
/// stack from two constants, 0x121 and 0x845A, right before the call that
/// sends it. That pair is there exactly once in every second stage looked at
/// (iBoot-5540 of 2020, iBoot-8422 of audioOS 16.4, iBoot-13822 of 2025) and
/// in no first stage.
public enum IBootFlipCheck {
    public enum Outcome: Equatable, Sendable {
        /// The call at this offset in the image is now a no-op.
        case removed(offset: Int)
        /// It was taken out before (the call is already a no-op).
        case alreadyRemoved(offset: Int)
        /// The image has no such place (not a second stage, or a shape this doesn't know).
        case notFound
        /// More than one candidate: nothing was changed.
        case ambiguous(count: Int)
    }

    /// `movz wN, #0x121`, any register.
    static let headConstant: UInt32 = 0x5280_0000 | (0x121 << 5)
    /// `movz wN, #0x845a`, any register.
    static let tailConstant: UInt32 = 0x5280_0000 | (0x845A << 5)
    static let registerMask: UInt32 = 0xFFFF_FFE0
    /// `bl <anywhere>`
    static let callMask: UInt32 = 0xFC00_0000
    static let call: UInt32 = 0x9400_0000
    static let nop: UInt32 = 0xD503_201F

    /// Where the message is sent: for every place where the two constants are
    /// loaded within a few instructions of each other, the offset of the first
    /// call (or the no-op that replaced it) after them. `base` is where the
    /// code starts in `image` and sets the instruction alignment.
    static func sites(in image: Data, base: Int = 0) -> [(offset: Int, isCall: Bool)] {
        let bytes = [UInt8](image)
        func word(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        var found: [(offset: Int, isCall: Bool)] = []
        let last = bytes.count - 4
        var i = base
        while i <= last {
            defer { i += 4 }
            guard word(i) & registerMask == headConstant else { continue }
            // the second constant, at most six instructions on
            var j = i + 4
            var tail: Int?
            while j <= min(i + 24, last) {
                if word(j) & registerMask == tailConstant { tail = j; break }
                j += 4
            }
            guard let tail else { continue }
            // the call that sends it, at most eight instructions after that
            var k = tail + 4
            while k <= min(tail + 32, last) {
                let w = word(k)
                if w & callMask == call { found.append((k, true)); break }
                if w == nop { found.append((k, false)); break }
                k += 4
            }
        }
        return found
    }

    /// Takes the check out of a raw (decrypted) second-stage image, in place.
    @discardableResult
    public static func remove(from image: inout Data) -> Outcome {
        let found = sites(in: image)
        guard !found.isEmpty else { return .notFound }
        guard found.count == 1 else { return .ambiguous(count: found.count) }
        let site = found[0]
        guard site.isCall else { return .alreadyRemoved(offset: site.offset) }
        let start = image.startIndex + site.offset
        image.replaceSubrange(start..<(start + 4), with: [UInt8(nop & 0xFF), UInt8((nop >> 8) & 0xFF),
                                                          UInt8((nop >> 16) & 0xFF), UInt8((nop >> 24) & 0xFF)])
        return .removed(offset: site.offset)
    }

    /// Does a boot loader file (raw, or wrapped as IMG4, where the code can
    /// start at any byte) still make the check? nil when the place isn't found.
    public static func isPresent(in file: Data) -> Bool? {
        for base in 0..<4 {
            let found = sites(in: file, base: base)
            if found.count == 1 { return found[0].isCall }
        }
        return nil
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: (stamp: String, present: Bool?)] = [:]

    /// The same question for a boot loader file on disk. The answer is
    /// remembered until the file changes (the Nicotine page asks every time it
    /// redraws, and the file is most of a megabyte).
    public static func isPresent(inFileAt url: URL) -> Bool? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let changed = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let stamp = "\(size)-\(changed)"
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cache[url.path], hit.stamp == stamp { return hit.present }
        let present = (try? Data(contentsOf: url)).flatMap { isPresent(in: $0) }
        cache[url.path] = (stamp, present)
        return present
    }

    /// One line for the builder's log.
    public static func describe(_ outcome: Outcome) -> String {
        switch outcome {
        case .removed(let offset):
            return "Upside-down check taken out of the second stage (the call at 0x\(String(offset, radix: 16)))."
        case .alreadyRemoved:
            return "The second stage already has the upside-down check taken out."
        case .notFound:
            return "The upside-down check wasn't found in the second stage, so it is still in: turn the HomePod right-side up before booting."
        case .ambiguous(let count):
            return "Found \(count) places that look like the upside-down check; nothing was changed. Turn the HomePod right-side up before booting."
        }
    }
}

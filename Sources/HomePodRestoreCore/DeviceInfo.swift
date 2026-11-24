import Foundation

/// What USB mode an Apple device is in, based on its USB product ID.
public enum DeviceMode: String, Codable, Sendable {
    case dfu            // 0x1227 — where restores start
    case recovery       // 0x1280–0x1283 — iBoot recovery
    case restore        // restore ramdisk / normal OS (usbmux)
    case unknown

    public init(productID: Int) {
        switch productID {
        case 0x1227: self = .dfu
        case 0x1280...0x1283: self = .recovery
        case 0x1200...0x12FF: self = .restore
        default: self = .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .dfu: return "DFU mode"
        case .recovery: return "Recovery mode"
        case .restore: return "Restore mode"
        case .unknown: return "Connected"
        }
    }
}

/// Parsed iBoot USB serial string, e.g.
/// `CPID:7000 CPRV:11 CPFM:03 SCEP:01 BDID:38 ECID:001A2B3C4D5E6F70 IBFL:1C SRTG:[iBoot-1704.10] PWND:[checkm8]`
public struct IBootSerial: Equatable, Sendable {
    public var cpid: UInt32?
    public var cprv: UInt32?
    public var bdid: UInt32?
    public var ecid: UInt64?
    public var ibfl: UInt32?
    public var srtg: String?
    public var srnm: String?
    public var pwnd: String?
    public var raw: String

    public init(_ raw: String) {
        self.raw = raw
        var fields: [String: String] = [:]
        // Tokens are KEY:VALUE separated by spaces; values in [brackets] may contain spaces.
        let scanner = raw
        var i = scanner.startIndex
        while i < scanner.endIndex {
            while i < scanner.endIndex, scanner[i] == " " { i = scanner.index(after: i) }
            guard i < scanner.endIndex else { break }
            guard let colon = scanner[i...].firstIndex(of: ":") else { break }
            let key = String(scanner[i..<colon]).uppercased()
            var j = scanner.index(after: colon)
            var value = ""
            if j < scanner.endIndex, scanner[j] == "[" {
                let start = scanner.index(after: j)
                if let close = scanner[start...].firstIndex(of: "]") {
                    value = String(scanner[start..<close])
                    j = scanner.index(after: close)
                } else {
                    value = String(scanner[start...]); j = scanner.endIndex
                }
            } else {
                let end = scanner[j...].firstIndex(of: " ") ?? scanner.endIndex
                value = String(scanner[j..<end])
                j = end
            }
            fields[key] = value
            i = j
        }
        func hex32(_ k: String) -> UInt32? { fields[k].flatMap { UInt32($0, radix: 16) } }
        cpid = hex32("CPID")
        cprv = hex32("CPRV")
        bdid = hex32("BDID")
        ibfl = hex32("IBFL")
        ecid = fields["ECID"].flatMap { UInt64($0, radix: 16) }
        srtg = fields["SRTG"]
        srnm = fields["SRNM"]
        pwnd = fields["PWND"]
    }

    public var isPwned: Bool { pwnd != nil }
    /// The chip's own DFU: only the boot ROM puts its name (SRTG) in the string.
    public var isBootROM: Bool { srtg != nil }
    /// A8 (t7000) is the 1st-gen HomePod's SoC.
    public var isA8: Bool { cpid == 0x7000 }
    /// Which A8 board this is (nil when it isn't an A8 or the id is unknown).
    public var a8Board: A8Board? { isA8 ? A8Board.identify(bdid) : nil }
    /// A B238a (AudioAccessory1,1) board: production 0x38 or dev-fused 0x39.
    public var isHomePodBoard: Bool { a8Board?.kind == .homePod }
    public var ecidString: String? { ecid.map { String(format: "0x%016llX", $0) } }
}

/// One Apple USB device as seen by the Mac. The app's USB monitor produces these.
public struct ConnectedDevice: Identifiable, Equatable, Sendable {
    /// USB location ID — stable for a given physical port, so a HomePod keeps
    /// the same identity as it moves DFU → recovery → restore mode.
    public var locationID: UInt32
    public var productID: Int
    public var productName: String
    public var serial: String
    /// USB speed: 0 low, 1 full (12 Mbps), 2 high (480 Mbps), 3+ super
    public var speed: Int?

    public var id: UInt32 { locationID }
    public var mode: DeviceMode { DeviceMode(productID: productID) }
    public var iboot: IBootSerial? { (mode == .dfu || mode == .recovery) ? IBootSerial(serial) : nil }

    /// In DFU, but not the chip's own: a boot loader is running its DFU, either
    /// the one on the pod's flash (after a failed start, or when asked through
    /// the power chip) or one that was just sent over USB. The USB product ID
    /// is the same as real DFU; the serial string has no SRTG field and reads
    /// `SDOM:… IBFL:1D`. gaster (checkm8) only works in the boot ROM and hangs here.
    /// False while the string hasn't been read yet.
    public var isBootLoaderDFU: Bool {
        guard mode == .dfu, let ib = iboot, ib.cpid != nil else { return false }
        return !ib.isBootROM
    }

    public init(locationID: UInt32, productID: Int, productName: String, serial: String, speed: Int?) {
        self.locationID = locationID
        self.productID = productID
        self.productName = productName
        self.serial = serial
        self.speed = speed
    }

    /// A short, human port label like "Port 1-3".
    public var portLabel: String {
        // locationID is 0xBBPPPPPP: bus in the top byte, then one nibble per hub hop.
        let bus = (locationID >> 24) & 0xFF
        var hops: [String] = []
        var rest = locationID & 0x00FF_FFFF
        for _ in 0..<6 {
            let nibble = (rest >> 20) & 0xF
            if nibble == 0 { break }
            hops.append(String(nibble))
            rest = (rest << 4) & 0x00FF_FFFF
        }
        return "USB \(bus)" + (hops.isEmpty ? "" : "-" + hops.joined(separator: "."))
    }

    public var speedDescription: String {
        switch speed {
        case 0: return "Low speed (1.5 Mbps)"
        case 1: return "Full speed (12 Mbps)"
        case 2: return "High speed (480 Mbps)"
        case .some(let s) where s >= 3: return "SuperSpeed"
        default: return "Unknown"
        }
    }
}

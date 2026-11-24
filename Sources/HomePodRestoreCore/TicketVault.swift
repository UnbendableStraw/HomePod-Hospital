import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Saves Apple's signing tickets for a HomePod while Apple still hands them out.
///
/// A ticket is what makes one software version valid for one pod (it is tied
/// to the pod's ECID). Apple's server only gives tickets for the versions it
/// "signs" at that moment, and stops for a version without notice. A ticket
/// that was saved in time keeps working for boot loaders that start from the
/// pod's own flash, which is what any future way of starting a pod without
/// Apple's servers will need. So the app asks for them whenever it sees a
/// pod, once per pod and version, and keeps them on this Mac:
///
///     Application Support/HomePod Hospital/Tickets/<ECID>/<version>-<build>.shsh2
///
/// Nothing is sent anywhere but to Apple's signing server (by tsschecker), and
/// the build manifests are read from Apple's own download servers.
public struct TicketVault: Sendable {
    /// One software version to ask a ticket for.
    public struct Firmware: Sendable, Hashable {
        /// "18.3"
        public var version: String
        /// "22K557"
        public var build: String
        /// The IPSW or full OTA on Apple's servers; its BuildManifest.plist is what the ticket is asked for.
        public var url: URL

        public init(version: String, build: String, url: URL) {
            self.version = version; self.build = build; self.url = url
        }

        /// "18.3-22K557": the name of the ticket and manifest files.
        public var name: String { "\(version)-\(build)" }
    }

    public enum Outcome: Sendable, Equatable {
        case saved
        case alreadySaved
        /// Apple's server no longer gives tickets for this version.
        case notSigned
        case failed(String)
    }

    /// The board the tickets are for (HomePod 1st gen, production board).
    public static let boardConfig = "b238aap"

    /// audioOS 13.4.8: the last version with the boot loaders from before Apple
    /// hardened them, still signed in November 2026. ipsw.me's list is used
    /// first; this is here so the version is asked for even if it drops out of
    /// that list. The address is Apple's own.
    public static let pinned: [Firmware] = [
        Firmware(version: "13.4.8", build: "17M61",
                 url: URL(string: "https://updates.cdn-apple.com/2020SummerFCS/patches/061-92130/8A16C3EF-C092-49F3-B488-2E650E15A31E/com_apple_MobileAsset_SoftwareUpdate/4a4b05d1ce655293d7bbea24141c2fc9c0695cd4.zip")!)
    ]

    /// At most this many versions are asked for in one go.
    public static let limit = 6

    public var directory: URL
    public var tsschecker: URL
    public var session: URLSession

    public init(directory: URL = AppPaths.support.appendingPathComponent("Tickets", isDirectory: true),
                tsschecker: URL, session: URLSession = .shared) {
        self.directory = directory; self.tsschecker = tsschecker; self.session = session
    }

    // MARK: Which versions

    /// The versions worth asking for: everything ipsw.me marks as signed
    /// (IPSWs and full OTAs, no betas), one entry per build, newest first,
    /// then the pinned ones that are not in the list. ipsw.me can be wrong
    /// either way; Apple's server has the last word when the ticket is asked for.
    public static func candidates(ipsws: [IPSWMeFirmware], otas: [IPSWMeFirmware], pinned: [Firmware] = TicketVault.pinned) -> [Firmware] {
        var byBuild: [String: Firmware] = [:]
        var order: [String] = []
        func add(_ f: Firmware) {
            guard byBuild[f.build] == nil else { return }
            byBuild[f.build] = f; order.append(f.build)
        }
        // An IPSW first: its manifest sits at the top of the zip and it is the release build.
        for f in ipsws where f.signed && !f.isBeta { add(Firmware(version: f.displayVersion, build: f.buildid, url: f.url)) }
        for f in otas where f.signed && !f.isBeta && f.isFullOTA { add(Firmware(version: f.displayVersion, build: f.buildid, url: f.url)) }
        var list = order.compactMap { byBuild[$0] }
            .sorted { FirmwareCatalog.compareVersions($0.version, $1.version) == .orderedDescending }
        for p in pinned where byBuild[p.build] == nil { list.append(p) }
        return Array(list.prefix(limit))
    }

    // MARK: Where things are kept

    /// "00001A2B3C4D5E6F": sixteen hex digits, the way the pod's USB serial string shows it.
    public static func ecidName(_ ecid: UInt64) -> String { String(format: "%016llX", ecid) }

    public func folder(ecid: UInt64) -> URL {
        directory.appendingPathComponent(Self.ecidName(ecid), isDirectory: true)
    }

    public func ticketFile(ecid: UInt64, firmware: Firmware) -> URL {
        folder(ecid: ecid).appendingPathComponent(firmware.name + ".shsh2")
    }

    /// Build manifests are the same for every pod: kept once, next to the pods' folders.
    public func manifestFile(for firmware: Firmware) -> URL {
        directory.appendingPathComponent("Manifests", isDirectory: true)
            .appendingPathComponent("BuildManifest-" + firmware.name + ".plist")
    }

    /// A ticket of a believable size is on disk (a real one is several KB).
    public func hasTicket(ecid: UInt64, firmware: Firmware) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: ticketFile(ecid: ecid, firmware: firmware).path)[.size] as? NSNumber)?.intValue ?? 0
        return size > 1000
    }

    /// The versions this pod has no ticket for yet.
    public func missing(ecid: UInt64, from firmwares: [Firmware]) -> [Firmware] {
        firmwares.filter { !hasTicket(ecid: ecid, firmware: $0) }
    }

    /// The saved tickets of one pod, by file name.
    public func savedTickets(ecid: UInt64) -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: folder(ecid: ecid).path)) ?? []
        return items.filter { $0.hasSuffix(".shsh2") }.sorted()
    }

    // MARK: Asking Apple

    /// `tsschecker -d AudioAccessory1,1 -B b238aap -m <manifest> -e <ECID> -s<file>`.
    /// tsschecker wants the file name glued to `-s`.
    public func arguments(ecid: UInt64, manifest: URL, output: URL) -> [String] {
        ["-d", HomePodModel.identifier, "-B", Self.boardConfig, "-m", manifest.path,
         "-e", Self.ecidName(ecid), "-s" + output.path]
    }

    /// What a finished tsschecker run means.
    public static func outcome(exitCode: Int32, output: String, ticketWritten: Bool) -> Outcome {
        if ticketWritten { return .saved }
        if output.localizedCaseInsensitiveContains("is NOT signed") { return .notSigned }
        let last = output.split(separator: "\n").map(String.init).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0 != "done" })
        return .failed(last ?? "tsschecker gave no ticket (exit \(exitCode)).")
    }

    /// The version's BuildManifest.plist, read out of Apple's zip with range
    /// requests (a few hundred KB of a file that is gigabytes) and kept on disk.
    public func fetchManifest(for firmware: Firmware) async throws -> URL {
        let file = manifestFile(for: firmware)
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue, size > 1000 { return file }
        let source = HTTPRangeSource(url: firmware.url, session: session)
        let zip = try await ZipDirectory.read(from: source)
        // An IPSW has it at the top; an audioOS OTA under AssetData/boot/.
        guard let entry = zip.entry(named: "BuildManifest.plist")
                ?? zip.entry(named: "AssetData/boot/BuildManifest.plist")
                ?? zip.entries.first(where: { $0.name.hasSuffix("/BuildManifest.plist") }) else {
            throw ZipError.entryNotFound("BuildManifest.plist")
        }
        let data = try await ZipDirectory.contents(of: entry, in: source)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return file
    }

    /// Asks Apple for one ticket and saves it. Does nothing if it is saved already.
    public func save(ecid: UInt64, firmware: Firmware, onLog: @escaping @Sendable (String) -> Void = { _ in }) async -> Outcome {
        if hasTicket(ecid: ecid, firmware: firmware) { return .alreadySaved }
        let fm = FileManager.default
        let manifest: URL
        do {
            manifest = try await fetchManifest(for: firmware)
        } catch {
            return .failed("Couldn't read the build manifest for \(firmware.name): \(error.localizedDescription)")
        }
        let dir = folder(ecid: ecid)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return .failed("Couldn't create \(dir.path): \(error.localizedDescription)")
        }
        // tsschecker writes straight to the name it is given: use a temporary one,
        // so that a cut-off answer never looks like a saved ticket.
        let part = dir.appendingPathComponent(firmware.name + ".part")
        let final = ticketFile(ecid: ecid, firmware: firmware)
        try? fm.removeItem(at: part)
        let runner = ProcessRunner(executable: tsschecker, arguments: arguments(ecid: ecid, manifest: manifest, output: part),
                                   currentDirectory: dir)
        onLog("$ tsschecker " + runner.arguments.joined(separator: " "))
        guard let result = try? await runner.run(onLine: { line in onLog("  " + line) }) else {
            try? fm.removeItem(at: part)
            return .failed("tsschecker could not be started.")
        }
        let size = (try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.intValue ?? 0
        let written = size > 1000
        if written {
            try? fm.removeItem(at: final)
            do { try fm.moveItem(at: part, to: final) } catch {
                return .failed("Couldn't save \(final.lastPathComponent): \(error.localizedDescription)")
            }
        } else {
            try? fm.removeItem(at: part)
        }
        return Self.outcome(exitCode: result.exitCode, output: result.output, ticketWritten: written)
    }

    /// Saves every ticket this pod doesn't have yet. One line per version for the log.
    public func saveMissing(ecid: UInt64, firmwares: [Firmware],
                            onLog: @escaping @Sendable (String) -> Void = { _ in }) async -> [(firmware: Firmware, outcome: Outcome)] {
        var results: [(firmware: Firmware, outcome: Outcome)] = []
        for firmware in missing(ecid: ecid, from: firmwares) {
            if Task.isCancelled { break }
            results.append((firmware, await save(ecid: ecid, firmware: firmware, onLog: onLog)))
        }
        return results
    }

    /// One sentence for the app's log.
    public static func summary(_ results: [(firmware: Firmware, outcome: Outcome)]) -> String? {
        guard !results.isEmpty else { return nil }
        let saved = results.filter { $0.outcome == .saved }.map { $0.firmware.version }
        let unsigned = results.filter { $0.outcome == .notSigned }.map { $0.firmware.version }
        let failed = results.filter { if case .failed = $0.outcome { return true }; return false }.map { $0.firmware.version }
        var parts: [String] = []
        if !saved.isEmpty { parts.append("saved for " + saved.joined(separator: ", ")) }
        if !unsigned.isEmpty { parts.append("Apple no longer signs " + unsigned.joined(separator: ", ")) }
        if !failed.isEmpty { parts.append("couldn't get " + failed.joined(separator: ", ") + " (will try again next time)") }
        return parts.isEmpty ? nil : "Signing tickets: " + parts.joined(separator: "; ") + "."
    }
}

/// Looks after the tickets of every HomePod the app sees: once per pod in each
/// run of the app, in the background, without anything for the user to do.
public actor TicketKeeper {
    public static let shared = TicketKeeper()

    /// UserDefaults key. Set it to false to stop the app asking Apple for
    /// tickets by itself (`defaults write … saveSigningTickets -bool NO`).
    public static let defaultsKey = "saveSigningTickets"

    private var asked: Set<UInt64> = []
    private var candidates: [TicketVault.Firmware]?

    public init() {}

    /// The pods in this list a ticket can be asked for: a production HomePod
    /// board (0x38) in DFU or recovery mode, where its ECID can be read.
    public static func ecids(in devices: [ConnectedDevice]) -> [UInt64] {
        var seen: Set<UInt64> = []
        return devices.compactMap { device -> UInt64? in
            guard let ib = device.iboot, ib.isA8, ib.bdid == 0x38, let ecid = ib.ecid, ecid != 0 else { return nil }
            return seen.insert(ecid).inserted ? ecid : nil
        }
    }

    /// Call with every change of the USB device list. Returns at once; the
    /// work runs in the background and `onSummary` gets one sentence per pod
    /// when something was saved or could not be.
    public static func note(_ devices: [ConnectedDevice], defaults: UserDefaults = .standard,
                            onSummary: @escaping @Sendable (String) -> Void) {
        let ecids = Self.ecids(in: devices)
        guard !ecids.isEmpty else { return }
        if let enabled = defaults.object(forKey: defaultsKey) as? Bool, !enabled { return }
        guard let tsschecker = ToolLocator.locate(.tsschecker)?.url else { return }
        let vault = TicketVault(tsschecker: tsschecker)
        Task { await shared.look(after: ecids, vault: vault, onSummary: onSummary) }
    }

    /// The pods of this list that have not been looked after in this run yet.
    func claim(_ ecids: [UInt64]) -> [UInt64] {
        ecids.filter { asked.insert($0).inserted }
    }

    func look(after ecids: [UInt64], vault: TicketVault, onSummary: @escaping @Sendable (String) -> Void) async {
        let fresh = claim(ecids)
        guard !fresh.isEmpty else { return }
        if candidates == nil {
            let ipsws = (try? await FirmwareCatalog.fetch(HomePodModel.identifier, type: "ipsw", session: vault.session)) ?? []
            let otas = (try? await FirmwareCatalog.fetch(HomePodModel.identifier, type: "ota", session: vault.session)) ?? []
            candidates = TicketVault.candidates(ipsws: ipsws, otas: otas)
        }
        let list = candidates ?? TicketVault.pinned
        for ecid in fresh {
            let results = await vault.saveMissing(ecid: ecid, firmwares: list)
            if let summary = TicketVault.summary(results) {
                onSummary(summary + " They are kept in \(vault.folder(ecid: ecid).path).")
            }
        }
    }
}

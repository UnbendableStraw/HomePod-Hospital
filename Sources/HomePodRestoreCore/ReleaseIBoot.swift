import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Release boot loaders, built in the app from Apple's own files
//
// Nicotine boots on a patched pair of A8 boot loaders. Rather than ship Apple's
// development iBoot, the app builds the pair from the RELEASE iBSS/iBEC inside
// Apple's audioOS 16.4 update (build 20L497) — downloaded from Apple, decrypted
// on this HomePod and patched, entirely with tools bundled in the app. No
// Homebrew, no terminal, no network to GitHub.
//
// The pipeline is exactly HoolockLinux's `remote_boot` prep, and byte-for-byte
// the one SSHRD_Script/diags_boot.sh already proves on this board:
//
//   download iBSS.im4p / iBEC.im4p  (audioOS 16.4 OTA, HTTP range reads)
//   → gaster pwn ; gaster decrypt   (checkm8 AES on the pod → raw iBoot)
//   → hBootPatcher -airs            (sig-check, IORVBAR, AES)
//   → IBootFlipCheck (iBEC only)    (the upside-down check: four bytes)
//   → IMG4Wrap (in this file)       (wrap + sign with the A8 IM4M; no external tool)
//
// The IM4M is the generic A8 ticket that ships in this repository's Nicotine
// kit (nicotine/prebuilt/0x7000.im4m, copied into the app's Resources by
// build-app.sh). Nothing outside the repository is needed. See
// docs/nicotine-boot.md.

/// Wraps a raw payload and an IM4M ticket into an IMG4 file:
/// `SEQUENCE { IA5 "IMG4", SEQUENCE { IA5 "IM4P", IA5 fourcc, IA5 description,
/// OCTET STRING payload }, [0] { IM4M } }`. The same bytes nicotine/tools/pack.py
/// writes, so the app needs no img4 tool.
public enum IMG4Wrap {
    static func derLength(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 {
            bytes.insert(UInt8(v & 0xff), at: 0)
            v >>= 8
        }
        return [UInt8(0x80 | bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        return [tag] + derLength(content.count) + content
    }

    static func ia5(_ text: String) -> [UInt8] {
        return tlv(0x16, Array(text.utf8))
    }

    public static func wrap(payload: Data, fourcc: String, im4m: Data,
                            description: String = "Unknown") -> Data {
        var im4pBody: [UInt8] = ia5("IM4P")
        im4pBody += ia5(fourcc)
        im4pBody += ia5(description)
        im4pBody += tlv(0x04, [UInt8](payload))
        var img4Body: [UInt8] = ia5("IMG4")
        img4Body += tlv(0x30, im4pBody)
        img4Body += tlv(0xA0, [UInt8](im4m))
        return Data(tlv(0x30, img4Body))
    }
}

/// Builds `iBSS.img4` / `iBEC.img4` in a folder, streaming progress.
public final class ReleaseIBootBuilder: @unchecked Sendable {
    /// The bundled tools the build needs. The model resolves them (ToolLocator
    /// for gaster; bundled Resources for hBootPatcher and the IM4M).
    public struct Tools: Sendable {
        public var gaster: URL
        public var hBootPatcher: URL
        /// Generic A8 IM4M (nicotine-0x7000.im4m in Resources), used to sign the wrap.
        public var im4m: URL
        public init(gaster: URL, hBootPatcher: URL, im4m: URL) {
            self.gaster = gaster; self.hBootPatcher = hBootPatcher
            self.im4m = im4m
        }
    }

    public enum Stage: Int, CaseIterable, Comparable, Sendable {
        case checking, downloading, decrypting, patching, wrapping, done
        public static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
        public var title: String {
            switch self {
            case .checking: return "Checking"
            case .downloading: return "Downloading from Apple (audioOS 16.4)"
            case .decrypting: return "Decrypting on the HomePod"
            case .patching: return "Patching the boot loaders"
            case .wrapping: return "Signing"
            case .done: return "Done"
            }
        }
    }

    /// audioOS 16.4, the version HoolockLinux's release-iBoot route uses.
    public static let otaBuild = "20L497"

    public let outputDir: URL
    public let tools: Tools
    public var environment: [String: String]
    /// Override the OTA URL (tests / a pinned mirror). Normally resolved from ipsw.me.
    public var otaURLOverride: URL?

    private var runner: ProcessRunner?
    private var cancelled = false

    public init(outputDir: URL, tools: Tools,
                environment: [String: String] = ToolEnvironment.standard,
                otaURLOverride: URL? = nil) {
        self.outputDir = outputDir; self.tools = tools
        self.environment = environment; self.otaURLOverride = otaURLOverride
    }

    public var iBSS: URL { outputDir.appendingPathComponent("iBSS.img4") }
    public var iBEC: URL { outputDir.appendingPathComponent("iBEC.img4") }
    public var isPrepared: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: iBSS.path) && fm.fileExists(atPath: iBEC.path)
    }

    public enum Failure: Error, LocalizedError {
        case toolMissing(String)
        case otaNotFound
        case bootLoaderPathsNotFound
        case cancelledByUser
        case step(String, lastLines: String)

        public var errorDescription: String? {
            switch self {
            case .toolMissing(let t):
                return "\(t) isn't in the app bundle. Rebuild HomePod Hospital with BUNDLE_TOOLS=1."
            case .otaNotFound:
                return "Couldn't find Apple's audioOS 16.4 (build \(ReleaseIBootBuilder.otaBuild)) download. Check your internet connection and try again."
            case .bootLoaderPathsNotFound:
                return "Couldn't find iBSS/iBEC inside Apple's update. The build layout may have changed."
            case .cancelledByUser:
                return "Building the release boot loaders was stopped."
            case .step(let what, let last):
                return "\(what) failed.\n\n\(last)"
            }
        }
    }

    public func cancel() { cancelled = true; runner?.cancel() }
    private func checkCancelled() throws { if cancelled { throw Failure.cancelledByUser } }

    /// iBSS/iBEC paths inside the OTA, from its BuildManifest: the first build
    /// identity that lists both (there is one board, b238ap).
    public static func bootLoaderPaths(buildManifest: Data) -> (iBSS: String, iBEC: String)? {
        if let plist = try? PropertyListSerialization.propertyList(from: buildManifest, format: nil) as? [String: Any],
           let ids = plist["BuildIdentities"] as? [[String: Any]] {
            for id in ids {
                guard let manifest = id["Manifest"] as? [String: Any] else { continue }
                func path(_ key: String) -> String? {
                    ((manifest[key] as? [String: Any])?["Info"] as? [String: Any])?["Path"] as? String
                }
                if let s = path("iBSS"), let e = path("iBEC") { return (s, e) }
            }
        }
        // Fallback: scan the raw manifest for the two path strings, the way
        // remote_boot's awk does (some OTA manifests nest differently).
        if let text = String(data: buildManifest, encoding: .utf8) {
            func firstPath(_ needle: String) -> String? {
                for chunk in text.components(separatedBy: "<string>").dropFirst() {
                    guard let end = chunk.range(of: "</string>") else { continue }
                    let v = String(chunk[..<end.lowerBound])
                    if v.contains(needle) && v.hasSuffix(".im4p") { return v }
                }
                return nil
            }
            if let s = firstPath("iBSS"), let e = firstPath("iBEC") { return (s, e) }
        }
        return nil
    }

    /// Runs the whole build. One checkm8 at a time across the app (gaster pwns).
    @discardableResult
    public func run(stage: @escaping @Sendable (Stage, Double?) -> Void = { _, _ in },
                    onLog: @escaping @Sendable (String) -> Void) async throws -> (iBSS: URL, iBEC: URL) {
        let fm = FileManager.default
        try checkCancelled()
        stage(.checking, nil)
        for (name, url) in [("gaster", tools.gaster), ("hBootPatcher", tools.hBootPatcher)] {
            guard fm.isExecutableFile(atPath: url.path) else { throw Failure.toolMissing(name) }
        }
        guard fm.fileExists(atPath: tools.im4m.path) else { throw Failure.toolMissing("nicotine-0x7000.im4m") }

        let work = outputDir.appendingPathComponent(".work", isDirectory: true)
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 1. Resolve + download iBSS/iBEC from the audioOS 16.4 OTA.
        stage(.downloading, nil)
        let otaURL = try await resolveOTAURL()
        onLog("Apple audioOS 16.4 (build \(Self.otaBuild))")
        let (encBSS, encBEC) = try await downloadBootLoaders(from: otaURL, to: work,
                                                             progress: { p in stage(.downloading, p) })
        try checkCancelled()

        // The IM4M for the wrap: the generic A8 ticket bundled with the app.
        let im4m = tools.im4m

        // 2–4. Decrypt (gaster), patch (hBootPatcher), wrap (img4) — one checkm8.
        try await UnlockCoordinator.shared.run {
            try self.checkCancelled()
            stage(.decrypting, nil)
            onLog("gaster pwn")
            try await self.runTool(self.tools.gaster, ["pwn"], what: "Unlocking the HomePod (gaster pwn)", onLog: onLog)

            for (tag, enc) in [("ibss", encBSS), ("ibec", encBEC)] {
                try self.checkCancelled()
                let dec = work.appendingPathComponent("\(tag).dec")
                let patched = work.appendingPathComponent("\(tag).patched")
                let out = tag == "ibss" ? self.iBSS : self.iBEC

                stage(.decrypting, nil)
                try await self.runTool(self.tools.gaster, ["decrypt", enc.path, dec.path],
                                       what: "Decrypting \(tag) (gaster)", onLog: onLog)
                stage(.patching, nil)
                try await self.runTool(self.tools.hBootPatcher, ["-airs", dec.path, patched.path],
                                       what: "Patching \(tag) (hBootPatcher)", onLog: onLog)
                stage(.wrapping, nil)
                try? FileManager.default.removeItem(at: out)
                onLog("Signing \(tag)")
                var rawPayload = try Data(contentsOf: patched)
                if tag == "ibec" {
                    // Our own patch on top: with the upside-down check out, the pod
                    // boots in any position (IBootFlipCheck). Never fatal: if the
                    // place isn't found the boot loader is used as it is.
                    onLog(IBootFlipCheck.describe(IBootFlipCheck.remove(from: &rawPayload)))
                }
                let ticket = try Data(contentsOf: im4m)
                try IMG4Wrap.wrap(payload: rawPayload, fourcc: tag, im4m: ticket).write(to: out)
            }
        }

        guard isPrepared else { throw Failure.step("Building the release boot loaders", lastLines: "The two files weren't produced.") }
        stage(.done, 1)
        return (iBSS, iBEC)
    }

    // MARK: steps

    /// Resolve the audioOS 16.4 OTA URL from ipsw.me (same source the app uses
    /// for restore firmware), or the override.
    private func resolveOTAURL() async throws -> URL {
        if let u = otaURLOverride { return u }
        let otas = (try? await FirmwareCatalog.fetch(HomePodModel.identifier, type: "ota")) ?? []
        if let hit = otas.first(where: { $0.buildid == Self.otaBuild && $0.isFullOTA }) ?? otas.first(where: { $0.buildid == Self.otaBuild }) {
            return hit.url
        }
        throw Failure.otaNotFound
    }

    /// Streams iBSS.im4p and iBEC.im4p out of the remote OTA zip (range reads).
    private func downloadBootLoaders(from url: URL, to work: URL,
                                     progress: @escaping @Sendable (Double?) -> Void) async throws -> (iBSS: URL, iBEC: URL) {
        let src = HTTPRangeSource(url: url)
        let dir = try await ZipDirectory.read(from: src)
        // audioOS OTAs keep BuildManifest.plist and the boot files under
        // AssetData/boot/; a full IPSW keeps them at the root. Match either.
        guard let bm = dir.entries.first(where: { $0.name.hasSuffix("BuildManifest.plist") }) else {
            throw Failure.bootLoaderPathsNotFound
        }
        let prefix = String(bm.name.dropLast("BuildManifest.plist".count))   // "" or "AssetData/boot/"
        let manifest = try await ZipDirectory.contents(of: bm, in: src)
        guard let paths = Self.bootLoaderPaths(buildManifest: manifest) else { throw Failure.bootLoaderPathsNotFound }
        // The manifest's path is relative to the same prefix; fall back to a
        // suffix match if the layout differs.
        func zipEntry(_ rel: String) -> ZipEntry? {
            dir.entry(named: prefix + rel) ?? dir.entry(named: rel)
                ?? dir.entries.first { $0.name.hasSuffix("/" + rel) }
                ?? dir.entries.first { $0.name.hasSuffix("/" + (rel as NSString).lastPathComponent) }
        }
        guard let bssEntry = zipEntry(paths.iBSS), let becEntry = zipEntry(paths.iBEC) else {
            throw Failure.bootLoaderPathsNotFound
        }
        let outBSS = work.appendingPathComponent("iBSS.im4p")
        let outBEC = work.appendingPathComponent("iBEC.im4p")
        progress(nil)
        try await (ZipDirectory.contents(of: bssEntry, in: src)).write(to: outBSS, options: .atomic)
        progress(0.5)
        try await (ZipDirectory.contents(of: becEntry, in: src)).write(to: outBEC, options: .atomic)
        progress(1)
        return (outBSS, outBEC)
    }

    /// Runs one bundled tool, streaming its output; non-zero exit throws with
    /// the last lines. gaster prints its usage and exits 1, so a tool that
    /// writes its expected output file is treated as success too.
    private func runTool(_ exe: URL, _ args: [String], what: String,
                         onLog: @escaping @Sendable (String) -> Void) async throws {
        let recent = RingLog(limit: 20)
        let r = ProcessRunner(executable: exe, arguments: args, environment: environment, currentDirectory: outputDir)
        runner = r
        onLog("$ \(exe.lastPathComponent) \(args.joined(separator: " "))")
        let result = try await withTaskCancellationHandler {
            try await r.run(onLine: { line in recent.add(line); onLog("  " + line) })
        } onCancel: { r.cancel() }
        if result.wasCancelled || cancelled { throw Failure.cancelledByUser }
        if result.exitCode != 0 { throw Failure.step(what, lastLines: recent.text) }
    }
}

/// The last N lines seen, for an error message. Thread-safe.
final class RingLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func add(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(s)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
}

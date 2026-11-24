import Foundation

// MARK: - Nicotine (Linux) boot
//
// Nicotine is the Linux system for the 1st-gen HomePod (AudioAccessory1,1 /
// B238a). It is always booted tethered, from DFU:
//
//   checkm8 (gaster) → patched dev iBSS → patched dev iBEC →
//   Apple device tree → empty trust cache → m1n1 + kernel + initramfs
//   (packed as a "restore kernelcache") → bootx
//
// The proven sequence is `boot-linux.sh`, the shell script that lives in the
// Nicotine image folder next to its `img4/` directory. This file reproduces
// that script STEP FOR STEP (default mode: PAYLOAD=linux, TAGS=restore), with
// the same files, the same commands, the same pauses and the same rule for
// which failures stop the boot. Do not "improve" the sequence here; change the
// script first, prove it on a pod, then mirror it. `NicotineTests` pins the
// exact command list.
//
// The image folder is NOT part of this repository (the kernel image alone is
// over 40 MB and changes with every build). The app finds one as a *payload*:
// a folder the user picked, one built into the app bundle, or one imported
// into Application Support. That part is NicotinePayload.swift; this file only
// needs a folder. See docs/nicotine-boot.md.

/// The Nicotine image folder: `boot-linux.sh`, `homepod-config.sh` and an
/// `img4/` directory with the boot files.
public struct NicotineLayout: Sendable, Equatable {
    public let root: URL
    public init(root: URL) { self.root = root }

    /// Where the folder is on the bench Mac this was developed on. Used as the
    /// default only when it exists.
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/diagsstuffnic/linux-homepod", isDirectory: true)
    }

    /// The default folder, if it is there.
    public static func discover(extraRoots: [URL] = []) -> NicotineLayout? {
        for r in extraRoots + [defaultRoot] {
            let l = NicotineLayout(root: r)
            if l.folderExists && FileManager.default.fileExists(atPath: l.img4Dir.path) { return l }
        }
        return nil
    }

    public var img4Dir: URL { root.appendingPathComponent("img4", isDirectory: true) }
    /// Legacy Hoolock-patched development iBSS / iBEC. The app no longer sends
    /// these — it boots on release loaders from ReleaseIBootBuilder — but the
    /// paths remain for payloads that still carry them.
    public var iBSS: URL { img4Dir.appendingPathComponent("iBSS.dev-hoolock.img4") }
    public var iBEC: URL { img4Dir.appendingPathComponent("iBEC.dev-hoolock.img4") }
    /// Apple's device tree for the B238a, tagged `rdtr` (TAGS=restore).
    public var deviceTree: URL { img4Dir.appendingPathComponent("RestoreDeviceTree_b238aap.img4") }
    public var trustCache: URL { img4Dir.appendingPathComponent("RestoreTrustCache.img4") }
    /// m1n1 + Linux kernel + device tree + initramfs, tagged `rkrn` (PAYLOAD=linux).
    public var kernelCache: URL { img4Dir.appendingPathComponent("RestoreKernelCache_m1n1-linux.img4") }

    /// The release boot loaders built from Apple's own files (ReleaseIBootBuilder,
    /// or prep-release-iboot.sh for terminal users), kept next to the image
    /// folder. A payload inside the app bundle or in Application Support can't be
    /// written into, so the builder puts them elsewhere and passes that folder to
    /// the booter; this is only the default.
    public var releaseIBootDir: URL { root.appendingPathComponent("release-iboot", isDirectory: true) }
    /// The two files boot-linux.sh looks for with IBOOT_DIR set: plain names,
    /// not the "-dev-hoolock" ones. `dir` overrides `releaseIBootDir`.
    public func releaseIBSS(in dir: URL? = nil) -> URL { (dir ?? releaseIBootDir).appendingPathComponent("iBSS.img4") }
    public func releaseIBEC(in dir: URL? = nil) -> URL { (dir ?? releaseIBootDir).appendingPathComponent("iBEC.img4") }
    /// Both release boot loaders are present.
    public func hasReleaseIBoot(in dir: URL? = nil) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: releaseIBSS(in: dir).path) && fm.fileExists(atPath: releaseIBEC(in: dir).path)
    }
    /// Release boot loaders that are missing, as "release-iboot/iBSS.img4" paths
    /// (empty when both are there).
    public func missingReleaseIBoot(in dir: URL? = nil) -> [String] {
        let fm = FileManager.default
        return [releaseIBSS(in: dir), releaseIBEC(in: dir)]
            .filter { !fm.fileExists(atPath: $0.path) }
            .map { "release-iboot/" + $0.lastPathComponent }
    }

    /// The Mac-side settings script (save / restore / status).
    public var configScript: URL { root.appendingPathComponent("homepod-config.sh") }
    /// Where that script keeps one backup per pod.
    public var configDir: URL { root.appendingPathComponent("config", isDirectory: true) }

    /// The payload files that must be present before a boot: device tree, trust
    /// cache and the kernelcache. The boot loaders (iBSS/iBEC) are built
    /// separately from Apple's release firmware, so they are not payload files.
    public var bootFiles: [URL] { [kernelCache, deviceTree, trustCache] }

    public var folderExists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Boot files that are not there, as paths relative to the folder
    /// ("img4/iBSS.dev-hoolock.img4"). Empty when the folder is ready.
    public var missingBootFiles: [String] {
        let fm = FileManager.default
        return bootFiles.filter { !fm.fileExists(atPath: $0.path) }
            .map { "img4/" + $0.lastPathComponent }
    }

    public var isComplete: Bool { folderExists && missingBootFiles.isEmpty }

    public var hasConfigScript: Bool { FileManager.default.fileExists(atPath: configScript.path) }

    /// Settings backups homepod-config.sh has saved here (one per pod).
    public var savedBackups: [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: configDir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.lastPathComponent.hasPrefix("homepod-config-") && $0.lastPathComponent.hasSuffix(".tar.gz") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Size and date of the kernel image, to tell builds apart ("41.0 MB, 21 Nov 2026 07:03").
    public var imageDescription: String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: kernelCache.path),
              let size = (attrs[.size] as? NSNumber)?.doubleValue else { return nil }
        var text = String(format: "%.1f MB", size / 1_048_576.0)
        if let date = attrs[.modificationDate] as? Date {
            let f = DateFormatter()
            f.dateFormat = "d MMM yyyy HH:mm"
            text += ", " + f.string(from: date)
        }
        return text
    }
}

/// One command of the boot, exactly as boot-linux.sh runs it.
public struct NicotineBootStep: Sendable, Equatable {
    public enum Tool: String, Sendable { case gaster, irecovery }
    public let tool: Tool
    public let arguments: [String]
    /// The script stops here (`|| exit 1`) when the command fails.
    public let stopsOnFailure: Bool
    /// The script's `sleep` after the command, in seconds.
    public let pauseAfter: Double
    /// The script's "[*] …" line printed before the command, if it has one.
    public let announcement: String?

    public init(_ tool: Tool, _ arguments: [String], stopsOnFailure: Bool, pauseAfter: Double = 0, announcement: String? = nil) {
        self.tool = tool; self.arguments = arguments
        self.stopsOnFailure = stopsOnFailure; self.pauseAfter = pauseAfter
        self.announcement = announcement
    }
}

public enum NicotineError: Error, LocalizedError, Equatable {
    case folderMissing(String)
    case filesMissing(folder: String, files: [String])
    case toolMissing(String)
    case stepFailed(command: String, exitCode: Int32)
    /// The payload's MANIFEST is unusable; the text says why ("it lists no files").
    case manifestInvalid(String)
    /// A file the MANIFEST lists isn't in the payload.
    case payloadFileMissing(String)
    /// A file doesn't have the SHA-256 the MANIFEST gives for it.
    case checksumMismatch(file: String)
    case importFailed(String)

    public var errorDescription: String? {
        switch self {
        case .folderMissing(let path):
            return path.isEmpty ? "No Nicotine image folder is set." : "The Nicotine image folder doesn't exist: \(path)"
        case .filesMissing(let folder, let files):
            return "Missing in \(folder): " + files.joined(separator: ", ")
        case .toolMissing(let name):
            return "\(name) isn't installed."
        case .stepFailed(let command, let exitCode):
            return "\(command) failed (exit \(exitCode))."
        case .manifestInvalid(let why):
            return "The payload's MANIFEST can't be used: \(why)."
        case .payloadFileMissing(let file):
            return "The payload is incomplete: \(file) is missing."
        case .checksumMismatch(let file):
            return "\(file) is damaged or incomplete (its checksum doesn't match the payload's MANIFEST)."
        case .importFailed(let why):
            return why
        }
    }

    /// The catalogue entry that explains this failure in plain words.
    public var issue: KnownIssue? {
        switch self {
        case .folderMissing, .filesMissing: return ErrorCatalog.nicotineIssue("nicotine.files")
        case .manifestInvalid, .payloadFileMissing, .checksumMismatch, .importFailed:
            return ErrorCatalog.nicotineIssue("nicotine.damaged")
        case .toolMissing: return ErrorCatalog.nicotineIssue("nicotine.tools")
        case .stepFailed(let command, _):
            if command.hasPrefix("gaster") { return ErrorCatalog.nicotineIssue("nicotine.pwn") }
            if command.contains("iBSS") || command.contains("iBEC") { return ErrorCatalog.nicotineIssue("nicotine.iboot") }
            return ErrorCatalog.nicotineIssue("nicotine.payload")
        }
    }
}

/// Boots Nicotine on the HomePod in DFU: boot-linux.sh, natively.
public struct NicotineBooter: Sendable {
    public struct Config: Sendable {
        public var layout: NicotineLayout
        public var gaster: URL
        public var irecovery: URL
        /// When set, these two boot loaders are sent instead of the patched dev
        /// iBSS/iBEC — the app's equivalent of `IBOOT_DIR=… ./boot-linux.sh`.
        /// Everything after the bootloaders is unchanged.
        public var releaseIBoot: (iBSS: URL, iBEC: URL)?
        /// 1 = the script's own pauses. Tests pass 0.
        public var pauseScale: Double
        public var environment: [String: String]

        public init(layout: NicotineLayout, gaster: URL, irecovery: URL,
                    releaseIBoot: (iBSS: URL, iBEC: URL)? = nil, pauseScale: Double = 1,
                    environment: [String: String] = ToolEnvironment.standard) {
            self.layout = layout; self.gaster = gaster; self.irecovery = irecovery
            self.releaseIBoot = releaseIBoot
            self.pauseScale = pauseScale; self.environment = environment
        }
    }

    public let config: Config
    public init(config: Config) { self.config = config }

    /// What the script prints once `bootx` has been sent.
    public static let afterBootMessage = "bootx sent. Watch the UART at 115200 8N1. If Linux reaches the ramdisk a USB serial device (/dev/cu.usbmodem*) and a USB network interface (172.16.42.1) appear."

    /// boot-linux.sh in its default mode, command for command. With
    /// `releaseIBoot` set, the two boot loaders are those files instead of the
    /// patched dev ones (IBOOT_DIR mode); every later step is identical.
    public static func steps(for layout: NicotineLayout,
                             releaseIBoot: (iBSS: URL, iBEC: URL)? = nil) -> [NicotineBootStep] {
        let iBSS = releaseIBoot?.iBSS ?? layout.iBSS
        let iBEC = releaseIBoot?.iBEC ?? layout.iBEC
        let tag = releaseIBoot == nil ? "" : "   (Apple release)"
        return [
            NicotineBootStep(.gaster, ["pwn"], stopsOnFailure: true,
                             announcement: "Put the HomePod in DFU, then: gaster pwn"),
            NicotineBootStep(.gaster, ["reset"], stopsOnFailure: true, pauseAfter: 1),
            NicotineBootStep(.irecovery, ["-f", iBSS.path], stopsOnFailure: true, pauseAfter: 3,
                             announcement: "iBSS: \(iBSS.path)\(tag)"),
            NicotineBootStep(.irecovery, ["-f", iBEC.path], stopsOnFailure: true, pauseAfter: 4,
                             announcement: "iBEC: \(iBEC.path)\(tag)   (replug the cable now if the next step hangs)"),
            NicotineBootStep(.irecovery, ["-f", layout.deviceTree.path], stopsOnFailure: true,
                             announcement: "Apple device tree"),
            NicotineBootStep(.irecovery, ["-c", "devicetree"], stopsOnFailure: false),
            NicotineBootStep(.irecovery, ["-f", layout.trustCache.path], stopsOnFailure: false,
                             announcement: "Empty trust cache (older iBoots have no trust cache; an error here is not fatal)"),
            NicotineBootStep(.irecovery, ["-c", "firmware"], stopsOnFailure: false),
            NicotineBootStep(.irecovery, ["-f", layout.kernelCache.path], stopsOnFailure: true,
                             announcement: "m1n1 payload: \(layout.kernelCache.path)"),
            NicotineBootStep(.irecovery, ["-c", "bootx"], stopsOnFailure: false),
        ]
    }

    /// Checks the folder and the tools, the way the script does before it starts.
    public func preflight() throws {
        let layout = config.layout
        guard layout.folderExists else { throw NicotineError.folderMissing(layout.root.path) }
        let missing = layout.missingBootFiles
        guard missing.isEmpty else { throw NicotineError.filesMissing(folder: layout.root.path, files: missing) }
        if let rel = config.releaseIBoot {
            let fm0 = FileManager.default
            let gone = [rel.iBSS, rel.iBEC].filter { !fm0.fileExists(atPath: $0.path) }
                .map { "release-iboot/" + $0.lastPathComponent }
            guard gone.isEmpty else { throw NicotineError.filesMissing(folder: rel.iBSS.deletingLastPathComponent().path, files: gone) }
        }
        // A payload with a MANIFEST (bundled, imported, downloaded) is checked
        // file by file; a developer's folder without one is taken as it is.
        try NicotinePayloadVerifier.verify(root: layout.root)
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: config.gaster.path) else { throw NicotineError.toolMissing("gaster") }
        guard fm.isExecutableFile(atPath: config.irecovery.path) else { throw NicotineError.toolMissing("irecovery") }
    }

    /// Runs the boot. Returns once `bootx` has been sent; the pod then needs
    /// about half a minute before its USB network answers (see `NicotinePod`).
    /// Log lines look like the script's own output.
    public func boot(onLog: @escaping @Sendable (String) -> Void) async throws {
        try preflight()
        let cfg = config
        let steps = Self.steps(for: cfg.layout, releaseIBoot: cfg.releaseIBoot)

        // One checkm8 at a time across the whole app, like every other boot.
        try await UnlockCoordinator.shared.run {
            for step in steps {
                try Task.checkCancellation()
                if let line = step.announcement { onLog("[*] " + line) }
                let executable = step.tool == .gaster ? cfg.gaster : cfg.irecovery
                let command = ([step.tool.rawValue] + step.arguments).joined(separator: " ")
                onLog("    $ " + command)
                let runner = ProcessRunner(executable: executable, arguments: step.arguments,
                                           environment: cfg.environment)
                let result = try await withTaskCancellationHandler {
                    try await runner.run(onLine: { onLog("    " + $0) })
                } onCancel: {
                    runner.cancel()
                }
                if result.wasCancelled { throw CancellationError() }
                if result.exitCode != 0 {
                    onLog("    (exit \(result.exitCode))")
                    if step.stopsOnFailure {
                        // Name the file, not its whole path, in the message.
                        let short = ([step.tool.rawValue] + step.arguments.map { ($0 as NSString).lastPathComponent })
                            .joined(separator: " ")
                        throw NicotineError.stepFailed(command: short, exitCode: result.exitCode)
                    }
                }
                let pause = step.pauseAfter * cfg.pauseScale
                if pause > 0 { try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
            }
        }
        onLog("[*] " + Self.afterBootMessage)
    }
}

// MARK: - The booted pod

/// What `/etc/os-release` on the pod says.
public struct NicotinePodInfo: Sendable, Equatable {
    public var prettyName: String?
    public var version: String?

    public init(prettyName: String? = nil, version: String? = nil) {
        self.prettyName = prettyName; self.version = version
    }

    /// "Nicotine (Doof Different) — build 105"
    public var versionLine: String {
        switch (prettyName, version) {
        case let (n?, v?): return "\(n) — \(v)"
        case let (n?, nil): return n
        case let (nil, v?): return v
        default: return "unknown version"
        }
    }

    /// Reads PRETTY_NAME and VERSION out of an os-release file.
    public static func parse(osRelease text: String) -> NicotinePodInfo {
        var info = NicotinePodInfo()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            var value = String(line[line.index(after: eq)...])
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty else { continue }
            if key == "PRETTY_NAME" { info.prettyName = value }
            if key == "VERSION" { info.version = value }
        }
        return info
    }
}

/// A pod running Nicotine, reached over its USB network. Read-only: a
/// reachability check (what homepod-config.sh's `pod_up` does) and the version.
public struct NicotinePod: Sendable {
    /// The pod's own address on the USB network it brings up.
    public static let usbAddress = "172.16.42.1"
    /// The web UI (plain HTTP, port 80).
    public static var webUI: URL { URL(string: "http://\(usbAddress)/")! }

    public var host: String
    public var curl: URL
    public var ssh: URL

    public init(host: String = NicotinePod.usbAddress,
                curl: URL = URL(fileURLWithPath: "/usr/bin/curl"),
                ssh: URL = URL(fileURLWithPath: "/usr/bin/ssh")) {
        self.host = host; self.curl = curl; self.ssh = ssh
    }

    /// `curl -s -o /dev/null -m 3 http://<pod>/` — the web UI answers.
    /// (curl rather than URLSession: App Transport Security refuses plain HTTP.)
    public var reachabilityArguments: [String] { ["-s", "-o", "/dev/null", "-m", "3", "http://\(host)/"] }

    public func isReachable() async -> Bool {
        let runner = ProcessRunner(executable: curl, arguments: reachabilityArguments)
        let result = try? await runner.run(onLine: { _ in })
        return result?.exitCode == 0
    }

    /// Polls every 2 seconds, like the script's `wait_for_pod`.
    public func waitUntilReachable(timeoutSeconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(max(0, timeoutSeconds)))
        while true {
            if await isReachable() { return true }
            if Task.isCancelled || Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    /// root without a password (the pod's dropbear allows it). BatchMode keeps
    /// ssh from ever stopping to ask; the pod's host key changes with every
    /// boot (no storage), so it is neither checked nor remembered.
    public func sshArguments(_ command: String) -> [String] {
        ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
         "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=8", "-o", "BatchMode=yes",
         "root@\(host)", command]
    }

    /// PRETTY_NAME and VERSION from the pod's /etc/os-release.
    public func info() async throws -> NicotinePodInfo {
        let runner = ProcessRunner(executable: ssh, arguments: sshArguments("cat /etc/os-release"))
        let result = try await runner.run(onLine: { _ in })
        guard result.exitCode == 0 else {
            throw SysCfgError.transportUnavailable("Couldn't read the pod's version over SSH (exit \(result.exitCode)).")
        }
        return NicotinePodInfo.parse(osRelease: result.output)
    }
}

// MARK: - Saved settings (homepod-config.sh)

/// Under Linux the pod keeps nothing across a power cycle, so its settings
/// (WiFi, AirPlay name, Bluetooth pairings, sound and light settings) are kept
/// on the Mac by `homepod-config.sh` in the image folder. This runs that
/// script; it is deliberately not re-implemented here.
public struct NicotineSettings: Sendable {
    public enum Action: Sendable, Equatable {
        case save
        /// `restore --wait N`: wait up to N seconds for the pod to answer first.
        case restore(waitSeconds: Int)
        /// `restore --auto --wait N`: what the app does by itself after a boot.
        /// A pod that has already put back the settings it keeps on its own
        /// flash (Nicotine build 117) keeps those and takes only the boot sound
        /// from the Mac's backup; the Mac's copy is then refreshed from the pod.
        /// An older pod, or one with nothing stored, gets the backup as with `restore`.
        case autoRestore(waitSeconds: Int)
        case status

        public var arguments: [String] {
            switch self {
            case .save: return ["save"]
            case .restore(let wait): return ["restore", "--wait", String(max(0, wait))]
            case .autoRestore(let wait): return ["restore", "--auto", "--wait", String(max(0, wait))]
            case .status: return ["status"]
            }
        }

        public var title: String {
            switch self {
            case .save: return "Saving settings"
            case .restore, .autoRestore: return "Restoring saved settings"
            case .status: return "Checking settings"
            }
        }

        var isRestore: Bool {
            switch self {
            case .restore, .autoRestore: return true
            case .save, .status: return false
            }
        }
    }

    public let layout: NicotineLayout
    public var bash: URL
    /// Where the script keeps its backups (passed as HOMEPOD_CONFIG_DIR), or
    /// nil for its own default: `config/` next to the script. Set for a
    /// payload inside the app bundle or Application Support, which must not
    /// be written into (see NicotinePayload.configDirectoryOverride).
    public var configDirectory: URL?

    public init(layout: NicotineLayout, bash: URL = URL(fileURLWithPath: "/bin/bash"), configDirectory: URL? = nil) {
        self.layout = layout; self.bash = bash; self.configDirectory = configDirectory
    }

    /// The folder the backups are in.
    public var backupDirectory: URL { configDirectory ?? layout.configDir }

    /// Settings backups saved there (one per pod).
    public var savedBackups: [URL] { Self.backups(in: backupDirectory) }

    public static func backups(in directory: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.lastPathComponent.hasPrefix("homepod-config-") && $0.lastPathComponent.hasSuffix(".tar.gz") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The environment the script runs in: the usual one, plus
    /// HOMEPOD_CONFIG_DIR when the backups live elsewhere.
    public func environment(base: [String: String] = ToolEnvironment.standard) -> [String: String] {
        var env = base
        if let dir = configDirectory { env["HOMEPOD_CONFIG_DIR"] = dir.path }
        return env
    }

    /// Should the settings be put back by themselves once a freshly booted pod
    /// answers? Only when the option is on, the script is there and at least
    /// one backup exists. The script itself picks the backup that belongs to
    /// this pod, and says "nothing to restore" when there is none for it.
    public static func shouldAutoRestore(enabled: Bool, hasScript: Bool, backups: [URL]) -> Bool {
        enabled && hasScript && !backups.isEmpty
    }

    /// What a finished run means for the user.
    public enum Outcome: Sendable, Equatable {
        case done(String)
        /// Restore found no backup for this pod: not an error.
        case nothingToRestore
        /// Restored, but one step didn't go through (the script's exit 3).
        case partial(String)
        case failed(String)

        public var isFailure: Bool { if case .failed = self { return true }; return false }
    }

    /// Reads the script's exit code and output. The script prefixes its own
    /// lines with "homepod-config: ".
    public static func outcome(of action: Action, exitCode: Int32, output: String) -> Outcome {
        let prefix = "homepod-config: "
        let own = output.split(separator: "\n").filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        if action.isRestore, exitCode == 0, own.contains(where: { $0.contains("nothing to restore") }) {
            return .nothingToRestore
        }
        // The last line the script wrote itself; "(make one with: …)" style hints and
        // the "keep it private" reminder are not the result.
        let result = own.last(where: { !$0.hasPrefix("(") && !$0.contains("keep it private") }) ?? ""
        if exitCode == 0 { return .done(result.isEmpty ? "Done." : result) }
        if exitCode == 3 { return .partial(result.isEmpty ? "Restored, but one step didn't go through." : result) }
        return .failed(result.isEmpty ? "The settings script failed." : result)
    }

    /// The sentence shown under the buttons after a run that went through.
    /// `text` is the script's last line (see `outcome`).
    public static func doneMessage(_ text: String, automatic: Bool) -> String {
        // A pod that kept the settings from its own flash: the script's line says so.
        if text.hasPrefix("this pod is using the settings it keeps itself") {
            return "This HomePod put its own saved settings back when it started"
                + (text.contains("was updated from it") ? "; the copy on this Mac was updated from it." : ".")
        }
        return (automatic ? "Saved settings put back automatically: " : "") + text
    }

    /// Runs `homepod-config.sh <action>` in the image folder. Exit code 0 means
    /// the script was satisfied; its last output line says what happened.
    public func run(_ action: Action, onLog: @escaping @Sendable (String) -> Void) async throws -> ProcessRunner.Result {
        guard layout.hasConfigScript else {
            throw SysCfgError.transportUnavailable("homepod-config.sh isn't in \(layout.root.path).")
        }
        if let dir = configDirectory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        let runner = ProcessRunner(executable: bash,
                                   arguments: [layout.configScript.path] + action.arguments,
                                   environment: environment(),
                                   currentDirectory: layout.root)
        return try await runner.run(onLine: onLog)
    }
}

// MARK: - Plain-words explanations

public extension ErrorCatalog {
    /// Failures of the Nicotine boot. Kept apart from `all`: those patterns are
    /// matched against restore logs, these are picked by `NicotineError.issue`.
    static let nicotine: [KnownIssue] = [
        KnownIssue(id: "nicotine.files",
                   title: "The Nicotine image folder isn't complete",
                   explanation: "The boot needs three files in the payload's img4 folder: Apple's device tree, an empty trust cache and the Nicotine image itself. (The boot loaders are built separately, on the Boot loaders card.)",
                   suggestions: ["Choose a Nicotine payload folder (it has an img4 folder inside), or rebuild the app so the payload is built in.",
                                 "If a file is missing, copy the whole folder again from where you keep Nicotine builds."],
                   severity: .fatal, category: .mac, patterns: []),
        KnownIssue(id: "nicotine.damaged",
                   title: "The Nicotine payload is damaged or incomplete",
                   explanation: "Every file of a Nicotine payload is listed with a checksum in its MANIFEST, and the app checks them before each boot. A file that doesn't match is almost always an interrupted download or copy; booting it would fail on the HomePod, where nothing shows why.",
                   suggestions: ["Download or copy the payload again, then use \"Import Nicotine payload…\" on the Nicotine page.",
                                 "If the payload is the one built into the app, download HomePod Hospital again."],
                   severity: .fatal, category: .mac, patterns: []),
        KnownIssue(id: "nicotine.tools",
                   title: "gaster or irecovery isn't installed",
                   explanation: "The Nicotine boot uses the same two tools as a restore: gaster to unlock the HomePod and irecovery to send it the boot files.",
                   suggestions: ["Click \"Install tools…\" on the Nicotine page (or open Setup), let the installer finish, then try again.",
                                 "A copy of HomePod Hospital built with the tools inside needs no installer; on an Intel Mac the tools inside an Apple-silicon build can't be used and the installer is needed."],
                   severity: .fatal, category: .mac, patterns: []),
        KnownIssue(id: "nicotine.pwn",
                   title: "The HomePod didn't unlock (gaster)",
                   explanation: "gaster couldn't put the HomePod into its unlocked DFU state. Usually it isn't in DFU mode, or the USB adapter isn't seated well.",
                   suggestions: ["Check the HomePod shows as \"DFU mode\" on the Restore page.",
                                 ErrorCatalog.reseat,
                                 "Try again — the unlock sometimes needs a second attempt."],
                   severity: .fatal, category: .connection, patterns: []),
        KnownIssue(id: "nicotine.iboot",
                   title: "The bootloader didn't go across",
                   explanation: "Sending iBSS or iBEC failed. The HomePod reconnects over USB between these steps, and that reconnect sometimes doesn't happen cleanly.",
                   suggestions: ["Unplug and replug the USB cable at the Mac, put the HomePod back in DFU and boot again.",
                                 "Avoid USB hubs for this step."],
                   severity: .fatal, category: .connection, patterns: []),
        KnownIssue(id: "nicotine.payload",
                   title: "The Nicotine image didn't go across",
                   explanation: "The bootloaders started, but sending the device tree or the Nicotine image failed.",
                   suggestions: ["Put the HomePod back in DFU (power off and on with USB connected) and boot again.",
                                 "If it keeps failing at the same file, that file may be damaged — copy the image folder again."],
                   severity: .fatal, category: .connection, patterns: []),
        KnownIssue(id: "nicotine.nonetwork",
                   title: "Nicotine was started, but the HomePod isn't answering",
                   explanation: "All boot files were sent, but nothing answered at 172.16.42.1. Nicotine brings up a USB network about half a minute after it starts; if Linux stopped earlier, only the serial (UART) console shows why.",
                   suggestions: ["Give it another minute, then click \"Check again\".",
                                 "Look in System Settings → Network for a new USB network connection.",
                                 "If you log the UART console, the last lines there say how far the boot got.",
                                 "Make sure the HomePod is right-side up, then boot again."],
                   severity: .warning, category: .connection, patterns: []),
    ]

    static func nicotineIssue(_ id: String) -> KnownIssue? { nicotine.first { $0.id == id } }
}

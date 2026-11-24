import Foundation
import SwiftUI
import AppKit
@preconcurrency import UserNotifications
import HomePodRestoreCore

final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
}

/// Everything the UI shows for one USB port.
struct Slot: Identifiable {
    var id: UInt32 { locationID }
    let locationID: UInt32
    var device: ConnectedDevice?
    var job: JobState?
}

/// A running or finished job plus its latest snapshot.
final class JobState: ObservableObject, Identifiable {
    let job: RestoreJob
    @Published var snapshot: RestoreJob.Snapshot
    var id: UUID { job.id }

    init(job: RestoreJob) {
        self.job = job
        self.snapshot = job.currentSnapshot
    }

    var isRunning: Bool { snapshot.outcome == .running }
}

struct DownloadState: Equatable {
    var progress: DownloadProgress?
    var error: String?
    static func == (a: DownloadState, b: DownloadState) -> Bool {
        a.progress?.received == b.progress?.received && a.error == b.error
    }
}

@MainActor
final class AppModel: ObservableObject {
    // Devices & jobs
    @Published private(set) var devices: [ConnectedDevice] = []
    @Published private(set) var jobs: [UInt32: JobState] = [:]
    @Published private(set) var history: [JobState] = []
    /// NAND health read from running pods, by USB location (AppModelNAND).
    @Published var nandHealth: [UInt32: NANDHealthState] = [:]

    // Tools
    @Published private(set) var tools: [ToolStatus] = []
    @Published private(set) var checkingTools = false
    @Published private(set) var gasterSupportsECID = false

    // Firmware
    @Published private(set) var manifest = PrebuiltManifest.fallback
    @Published private(set) var library: [FirmwareItem] = []
    @Published var selectedFirmwareID: String? {
        didSet { UserDefaults.standard.set(selectedFirmwareID, forKey: "selectedFirmware") }
    }
    @Published private(set) var downloads: [String: DownloadState] = [:]
    @Published private(set) var preparing: [String: Double] = [:]
    @Published private(set) var prepareError: String?
    @Published private(set) var signedStatus: [String: Bool] = [:]

    // Builder
    @Published private(set) var releases: [BuildableRelease] = []
    @Published private(set) var releasesError: String?
    @Published private(set) var loadingReleases = false
    @Published private(set) var build: BuildState?

    // SysCfg (experimental — read/restore per-unit config over the SSH ramdisk)
    @Published var syscfg: SysCfgUIState?
    @Published var sshRamdiskBuild: SSHRamdiskBuildState?
    var sshRamdiskBuilder: SSHRamdiskBuilder?
    var syscfgTask: Task<Void, Never>?
    /// How the pod gets into the SSH ramdisk for SysCfg / diagnostics.
    @Published var syscfgBootMode: SysCfgBootMode {
        didSet { UserDefaults.standard.set(syscfgBootMode.rawValue, forKey: "syscfgBootMode") }
    }
    // Diagnostics (read-only panic-log + ioreg pull)
    @Published var diag: DiagUIState?
    var diagTask: Task<Void, Never>?
    // SSHRD ramdisk build (the proven create step, driven by the app)
    @Published var sshrdBuild: SSHRDBuildState?
    var sshrdBuildTask: Task<Void, Never>?
    // Full diagnostics (hpdiag suite — NAND health, partitions, factory data, etc.)
    @Published var fullDiag: FullDiagUIState?
    var fullDiagTask: Task<Void, Never>?

    // DIAGS shell over serial (UART) — a USB-to-serial adapter, independent of
    // the USB device list above. The logic lives in AppModelDiagsSerial.swift.
    @Published var diagsSession: DiagsSerialSession?
    /// The serial device selected in the DIAGS Shell port picker (/dev/cu.…).
    @Published var serialPortPath: String?
    @Published var serialPorts: [String] = []
    @Published var diagsConnecting = false
    /// Label of the DIAGS command (or batch) running now; nil when idle.
    @Published var diagsBusy: String?
    @Published var diagsError: String?
    /// The unit's ECID as printed in the DIAGS prompt.
    @Published var diagsECID: String?
    /// "Amp Init" has initialised the amp controller on this connection.
    @Published var diagsAudioReady = false
    @Published var diagsLog: [DiagsLogEntry] = []
    /// Bumped on every change to `diagsLog` (drives auto-scroll).
    @Published var diagsLogRevision = 0
    @Published var diagsSysCfgEntries: [SysCfgEntry] = []
    /// The `syscfg list` output the entries were parsed from (for Save / Copy).
    @Published var diagsSysCfgRaw: String?
    @Published var diagsSysCfgWriteStatus: String?
    @Published var diagsSysCfgWriteFailed = false
    /// The unit's model number (SysCfg `Mod#`) and region (`Regn`) as last
    /// read over the DIAGS shell — shown by the Reconfigure Model sheet.
    @Published var diagsCurrentModel: String?
    @Published var diagsCurrentRegion: String?
    /// The unit's colour keys — `CLCG` (Cover Glass Color) and `CLHS`
    /// (Housing Color) — as last read, keyed by SysCfg key. A key that hasn't
    /// been read, or isn't set, is absent.
    @Published var diagsCurrentColorKeys: [String: String] = [:]
    /// Outcome of the last model reconfiguration, for the sheet.
    @Published var diagsModelStatus: String?
    @Published var diagsModelFailed = false
    var diagsIdleTask: Task<Void, Never>?

    // Board health (per-ECID hardware fault tracking)
    @Published private(set) var boardHealth: [UInt64: BoardHealthRecord] = BoardHealthStore.load()

    // Settings
    @Published var autoRestore: Bool {
        didSet { UserDefaults.standard.set(autoRestore, forKey: "autoRestore") }
    }
    @Published var showAdvanced: Bool {
        didSet { UserDefaults.standard.set(showAdvanced, forKey: "showAdvanced") }
    }

    // Nicotine (Linux) boot — see AppModelNicotine.swift
    @Published var nicotine = NicotineUIState()
    /// A Nicotine image folder the user picked: the one boot-linux.sh lives in
    /// (its img4/ holds the boot files). Empty = none picked; the payload built
    /// into the app or an imported one is used then (see `nicotinePayload`).
    @Published var nicotineFolderPath: String {
        didSet { UserDefaults.standard.set(nicotineFolderPath, forKey: "nicotineFolder") }
    }
    /// Put a pod's saved settings back by themselves once it answers after a boot.
    @Published var nicotineAutoRestore: Bool {
        didSet { UserDefaults.standard.set(nicotineAutoRestore, forKey: "nicotineAutoRestore") }
    }
    /// Bumped to make RootView switch to the Nicotine page.
    @Published var nicotineRevealToken = 0
    var nicotineTask: Task<Void, Never>?
    var nicotineSettingsTask: Task<Void, Never>?
    var nicotinePrepareTask: Task<Void, Never>?

    let firmwareLibrary = FirmwareLibrary()
    private var monitor: USBMonitor?
    private var downloaders: [String: FileDownloader] = [:]
    private var prepareTasks: [String: Task<Void, Error>] = [:]
    private var builder: IPSWBuilder?
    private var recentlyRestored: [UInt64: Date] = [:]

    struct BuildState {
        var release: BuildableRelease
        var update: IPSWBuilder.Update
        var log: [String]
        var error: String?
        var finished: URL?
        var running: Bool { error == nil && finished == nil }
    }

    init() {
        autoRestore = UserDefaults.standard.bool(forKey: "autoRestore")
        showAdvanced = UserDefaults.standard.bool(forKey: "showAdvanced")
        nicotineFolderPath = UserDefaults.standard.string(forKey: "nicotineFolder")
            ?? NicotineLayout.discover()?.root.path ?? ""
        nicotineAutoRestore = UserDefaults.standard.object(forKey: "nicotineAutoRestore") as? Bool ?? true
        if let raw = UserDefaults.standard.string(forKey: "syscfgBootMode"),
           let m = SysCfgBootMode(rawValue: raw) {
            syscfgBootMode = m
        } else {
            syscfgBootMode = SSHRDLayout.discover() != nil ? .sshrd : .preBooted
        }
        selectedFirmwareID = UserDefaults.standard.string(forKey: "selectedFirmware")
        AppPaths.ensure()
        library = firmwareLibrary.items
        if selectedFirmwareID == nil || !library.contains(where: { $0.id == selectedFirmwareID }) {
            selectedFirmwareID = library.first?.id
        }
    }

    func start() {
        guard monitor == nil else { return }
        monitor = USBMonitor { [weak self] devs in self?.devicesChanged(devs) }
        monitor?.start()
        Task { await refreshTools() }
        Task { await refreshManifest() }
        Task { await loadSigningStatus() }
    }

    // MARK: - Derived

    var selectedFirmware: FirmwareItem? { library.first { $0.id == selectedFirmwareID } }

    var donateURL: URL { manifest.donateURL ?? Links.donate }
    var discordURL: URL { manifest.discordURL ?? Links.discord }

    var restoreToolsReady: Bool {
        Tool.allCases.filter(\.isRequiredForRestore).allSatisfy { t in tools.first { $0.tool == t }?.isInstalled == true }
    }

    var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    /// One card per USB port that has a HomePod or a job.
    var slots: [Slot] {
        var ids = Set(devices.map(\.locationID))
        ids.formUnion(jobs.keys)
        return ids.sorted().map { id in
            Slot(locationID: id, device: devices.first { $0.locationID == id }, job: jobs[id])
        }
    }

    var runningJobCount: Int { jobs.values.filter(\.isRunning).count }

    func isSigned(_ build: String) -> Bool? { signedStatus[build] }

    // MARK: - Devices

    private func devicesChanged(_ new: [ConnectedDevice]) {
        devices = new
        // Signing tickets for every pod that shows up, while Apple still gives them
        // out (TicketVault in the core). Background work; once per pod and run.
        TicketKeeper.note(new) { [weak self] line in Task { @MainActor in self?.appendNicotineLog(line) } }
        // A finished card stays up (so its "unplug power, then USB…" steps stay
        // visible) until a *different* HomePod shows up on that port.
        for d in new {
            if let j = jobs[d.locationID], !j.isRunning, let e = d.iboot?.ecid, e != j.job.ecid {
                history.insert(j, at: 0)
                jobs[d.locationID] = nil
            }
        }
        if autoRestore { autoStartIfPossible() }
    }

    private func autoStartIfPossible() {
        guard restoreToolsReady, let fw = selectedFirmware else { return }
        for d in devices where d.mode == .dfu {
            // Any job on this port (running or finished) means this HomePod was already handled.
            guard jobs[d.locationID] == nil, let ib = d.iboot, ib.isA8, let ecid = ib.ecid else { continue }
            if let t = recentlyRestored[ecid], Date().timeIntervalSince(t) < 15 * 60 { continue }
            guard blocker(for: d, kind: .restore) == nil else { continue }
            startJob(.restore, on: d, firmware: fw)
        }
    }

    /// Why a restore can't start right now (nil = good to go).
    func blocker(for device: ConnectedDevice, kind: RestoreJob.Kind) -> String? {
        if !restoreToolsReady { return "Install the restore tools first (Setup)." }
        if kind != .quickCheck && selectedFirmware == nil { return "Choose or download firmware first." }
        guard device.mode == .dfu else { return "The HomePod needs to be in DFU mode." }
        guard let ib = device.iboot, ib.ecid != nil else { return "Couldn't read this device's ID." }
        // The boot loader's own DFU looks like DFU on USB, but gaster hangs there. A pod
        // that one of our own boots is sending boot loaders to looks the same for a
        // moment, so this only speaks up when nothing of ours is running on it.
        if device.isBootLoaderDFU && jobs[device.locationID]?.isRunning != true && !nicotine.isBusy
            && syscfg?.running != true && diag?.running != true && fullDiag?.running != true {
            return DFUInstructions.fromBootLoaderDFU
        }
        // A quick check only unlocks the chip, so any HomePod board will do. A
        // restore or boot test needs a firmware build for this exact board.
        if let why = kind == .quickCheck ? A8BoardGate.bootBlocker(ib) : A8BoardGate.restoreBlocker(ib) {
            return why
        }
        if !gasterSupportsECID {
            let otherDFU = devices.filter { $0.mode == .dfu && $0.locationID != device.locationID }
            let otherUnlocking = jobs.values.contains { $0.isRunning && $0.snapshot.phase <= .unlocking && $0.job.locationID != device.locationID }
            if !otherDFU.isEmpty || otherUnlocking {
                return "Your gaster can only handle one HomePod in DFU mode at a time. Wait for the other one to start restoring, or install the multi-HomePod tools in Setup."
            }
        }
        return nil
    }

    func startJob(_ kind: RestoreJob.Kind, on device: ConnectedDevice, firmware: FirmwareItem? = nil) {
        guard blocker(for: device, kind: kind) == nil, let ecid = device.iboot?.ecid else { return }
        if let existing = jobs[device.locationID], existing.isRunning { return }
        if let old = jobs.removeValue(forKey: device.locationID) { history.insert(old, at: 0) }
        let fw = kind == .quickCheck ? nil : (firmware ?? selectedFirmware)
        let location = device.locationID

        let stateRef = WeakBox<JobState>()
        let job = RestoreJob(kind: kind, ecid: ecid, locationID: location, firmware: fw,
                             gasterTargetsECID: gasterSupportsECID) { snap in
            Task { @MainActor in
                guard let st = stateRef.value, snap.sequence >= st.snapshot.sequence else { return }
                st.snapshot = snap
                self.objectWillChange.send()
                self.jobUpdated(location: location, ecid: ecid, snap: snap)
            }
        }
        let state = JobState(job: job)
        stateRef.value = state
        jobs[location] = state

        Task.detached {
            // Make sure the root filesystem is unpacked once before any restore uses it.
            if let fw, kind != .quickCheck {
                do { try await self.prepareFirmware(fw) }
                catch {
                    await MainActor.run {
                        state.snapshot.outcome = .failed(issueID: "fw.extract", message: "Couldn't unpack the firmware: \(error.localizedDescription)")
                        state.snapshot.status = "Couldn't unpack the firmware"
                        self.objectWillChange.send()
                    }
                    return
                }
            }
            await job.run()
        }
    }

    private func jobUpdated(location: UInt32, ecid: UInt64, snap: RestoreJob.Snapshot) {
        guard snap.outcome != .running else { return }

        // Update board health record from the finished job.
        updateBoardHealth(ecid: ecid, snapshot: snap)

        if snap.outcome == .succeeded {
            if snap.kind == .restore {
                recentlyRestored[ecid] = Date()
                notify(title: "HomePod restored", body: "Unplug power, then USB, remove the adapter, and set it up in the Home app.")
            }
        } else if case .failed = snap.outcome {
            notify(title: "HomePod restore stopped", body: snap.primaryIssue?.title ?? snap.status)
        }
    }

    // MARK: - Board Health

    /// Look up the stored health record for a device (by ECID).
    func healthRecord(for device: ConnectedDevice) -> BoardHealthRecord? {
        guard let ecid = device.iboot?.ecid else { return nil }
        return boardHealth[ecid]
    }

    /// Update the health record for a board after a job finishes.
    func updateBoardHealth(ecid: UInt64, snapshot: RestoreJob.Snapshot) {
        var record = boardHealth[ecid] ?? BoardHealthRecord(ecid: ecid)
        record.update(from: snapshot)
        boardHealth[ecid] = record
        BoardHealthStore.save(boardHealth)
    }

    /// Update from UART log data (called from DIAGS serial session).
    func updateBoardHealthFromUART(ecid: UInt64, log: String) {
        var record = boardHealth[ecid] ?? BoardHealthRecord(ecid: ecid)
        record.updateFromUART(log)
        boardHealth[ecid] = record
        BoardHealthStore.save(boardHealth)
    }

    /// Clear a stored health record (e.g. after a board repair).
    func clearBoardHealth(ecid: UInt64) {
        boardHealth.removeValue(forKey: ecid)
        BoardHealthStore.save(boardHealth)
    }

    func cancel(_ state: JobState) { state.job.cancel() }

    func dismiss(_ slot: Slot) {
        guard let j = jobs[slot.locationID], !j.isRunning else { return }
        history.insert(j, at: 0)
        jobs[slot.locationID] = nil
    }

    func retry(_ slot: Slot, as kind: RestoreJob.Kind? = nil) {
        guard let d = slot.device, let j = slot.job else { return }
        startJob(kind ?? j.job.kind, on: d, firmware: kind == nil ? j.job.firmware : nil)
    }

    func restoreAllReady() {
        for d in devices where d.mode == .dfu && jobs[d.locationID] == nil {
            if blocker(for: d, kind: .restore) == nil { startJob(.restore, on: d) }
        }
    }

    var readyDeviceCount: Int {
        devices.filter { $0.mode == .dfu && jobs[$0.locationID] == nil && blocker(for: $0, kind: .restore) == nil }.count
    }

    // MARK: - Tools

    func refreshTools() async {
        checkingTools = true
        var result: [ToolStatus] = []
        for t in Tool.allCases { result.append(await ToolLocator.status(of: t)) }
        tools = result
        gasterSupportsECID = await ToolLocator.gasterSupportsECID()
        checkingTools = false
    }

    func openInstaller(builder: Bool) {
        do {
            let url = try ToolInstaller.prepareScript(builder: builder)
            NSWorkspace.shared.open(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - Firmware

    func refreshManifest() async {
        manifest = await PrebuiltManifest.fetch()
    }

    func loadSigningStatus() async {
        guard let otas = try? await FirmwareCatalog.fetch(HomePodModel.identifier, type: "ota") else { return }
        var s: [String: Bool] = [:]
        for f in otas { s[f.buildid] = (s[f.buildid] ?? false) || f.signed }
        signedStatus = s
    }

    func reloadLibrary() {
        firmwareLibrary.load()
        library = firmwareLibrary.items
        if selectedFirmware == nil { selectedFirmwareID = library.first?.id }
    }

    func importFirmware(_ url: URL) async -> String? {
        do {
            let item = try await firmwareLibrary.add(url, origin: .imported)
            reloadLibrary()
            selectedFirmwareID = item.id
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func remove(_ item: FirmwareItem) {
        // Only delete files that live in our own folder; imported ones are just forgotten.
        let ours = item.path.hasPrefix(AppPaths.firmware.path)
        firmwareLibrary.remove(item, deleteFile: ours)
        reloadLibrary()
    }

    func isDownloading(_ entry: PrebuiltManifest.Entry) -> Bool { downloaders[entry.url.absoluteString] != nil }

    func localItem(for entry: PrebuiltManifest.Entry) -> FirmwareItem? {
        library.first { $0.info.buildVersion == entry.build && $0.origin == .prebuilt && $0.exists }
            ?? library.first { $0.info.buildVersion == entry.build && $0.exists }
    }

    func download(_ entry: PrebuiltManifest.Entry) {
        let key = entry.url.absoluteString
        guard downloaders[key] == nil else { return }
        if let free = AppPaths.freeSpace(at: AppPaths.firmware), let size = entry.size, free < size * 2 + 1_000_000_000 {
            downloads[key] = DownloadState(progress: nil, error: "Not enough disk space. You need about \(ByteFormat.string(size * 2)) free (the download plus unpacking).")
            return
        }
        let d = FileDownloader()
        downloaders[key] = d
        downloads[key] = DownloadState(progress: nil, error: nil)
        let dest = AppPaths.firmware.appendingPathComponent("HomePod-\(entry.version)-\(entry.build).ipsw")
        Task {
            do {
                let file = try await d.download(entry.url, to: dest, expectedSHA256: entry.sha256) { p in
                    Task { @MainActor in self.downloads[key] = DownloadState(progress: p, error: nil) }
                }
                let item = try await firmwareLibrary.add(file, origin: .prebuilt)
                downloaders[key] = nil
                downloads[key] = nil
                reloadLibrary()
                selectedFirmwareID = item.id
                // Unpack right away so the first restore starts quickly.
                try? await prepareFirmware(item)
            } catch {
                downloaders[key] = nil
                downloads[key] = DownloadState(progress: downloads[key]?.progress, error: error.localizedDescription)
            }
        }
    }

    func cancelDownload(_ entry: PrebuiltManifest.Entry) {
        let key = entry.url.absoluteString
        downloaders[key]?.cancel()
        downloaders[key] = nil
        downloads[key] = nil
    }

    /// Unpacks the root filesystem into the shared restore cache (once per firmware).
    nonisolated func prepareFirmware(_ item: FirmwareItem) async throws {
        if FilesystemCache.isReady(for: item) { return }
        let task: Task<Void, Error> = await MainActor.run {
            if let t = prepareTasks[item.id] { return t }
            let t = Task<Void, Error> {
                try await FilesystemCache.prepare(item) { p in
                    Task { @MainActor in self.preparing[item.id] = p }
                }
            }
            prepareTasks[item.id] = t
            return t
        }
        do {
            try await task.value
            await MainActor.run { prepareTasks[item.id] = nil; preparing[item.id] = nil }
        } catch {
            await MainActor.run { prepareTasks[item.id] = nil; preparing[item.id] = nil; prepareError = error.localizedDescription }
            throw error
        }
    }

    // MARK: - Build your own

    func loadReleases() async {
        loadingReleases = true
        releasesError = nil
        do {
            async let otas = FirmwareCatalog.fetch(HomePodModel.identifier, type: "ota")
            async let donors = FirmwareCatalog.fetch(HomePodModel.donorIdentifier, type: "ipsw")
            releases = FirmwareCatalog.buildableReleases(otas: try await otas, donors: try await donors)
        } catch {
            releasesError = "Couldn't reach ipsw.me: \(error.localizedDescription)"
        }
        loadingReleases = false
    }

    func startBuild(_ release: BuildableRelease) {
        guard build?.running != true else { return }
        let b = IPSWBuilder(release: release)
        builder = b
        build = BuildState(release: release, update: .init(stage: .checking, progress: nil, detail: ""), log: [], error: nil, finished: nil)
        Task {
            do {
                let url = try await b.run { u in
                    Task { @MainActor in
                        guard var s = self.build else { return }
                        s.update = u
                        if let l = u.logLine { s.log.append(l); if s.log.count > 2000 { s.log.removeFirst(500) } }
                        self.build = s
                    }
                }
                let item = try await firmwareLibrary.add(url, origin: .built)
                reloadLibrary()
                selectedFirmwareID = item.id
                build?.finished = url
                notify(title: "Firmware built", body: "\(item.displayName) is ready to restore.")
            } catch {
                build?.error = error.localizedDescription
            }
            builder = nil
        }
    }

    func cancelBuild() { builder?.cancel() }
    func clearBuild() { if build?.running != true { build = nil } }

    // MARK: - Support

    func supportReport(for slot: Slot) -> String {
        SupportReport.make(appVersion: appVersion, macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                           tools: tools, device: slot.device, snapshot: slot.job?.snapshot,
                           firmware: slot.job?.job.firmware ?? selectedFirmware)
    }

    func copyToClipboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func notify(title: String, body: String) {
        NSApp.requestUserAttention(.informationalRequest)
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

import Foundation
import AppKit
import HomePodRestoreCore

// MARK: - Nicotine (Linux) boot
//
// The third boot mode, next to the SSH ramdisk and Factory DIAGS. Same shape as
// the others (see AppModelSysCfg.swift / AppModelDiagnostics.swift): publish a
// UI-state struct, run the work in a Task, hop back to the main actor for every
// state change. The boot itself is NicotineBooter in the core library, which
// mirrors boot-linux.sh command for command.
//
// Wired in: `nicotine`, `nicotineFolderPath`, `nicotineAutoRestore`,
// `nicotineRevealToken` and the two tasks live in AppModel.swift; the page is
// Views/NicotineView.swift (sidebar section "Nicotine"); the device card offers
// "Boot Nicotine (Linux)".
//
// The boot files come from a *payload* (NicotinePayload.swift in the core):
// a folder the user picked, else the one built into the app, else one imported
// into Application Support. Background and file layout: docs/nicotine-boot.md.

/// UI state for the Nicotine page.
struct NicotineUIState {
    enum Stage: Equatable {
        case idle
        /// Sending the boot files (gaster + irecovery).
        case booting
        /// bootx sent; waiting for the pod's USB network.
        case waitingForPod
        /// The pod answers at 172.16.42.1.
        case up
        case failed
    }

    var stage: Stage = .idle
    var log: [String] = []
    var error: String?
    /// Plain-words explanation of `error`, when there is one.
    var issue: KnownIssue?

    /// A pod answers on the USB network (set by the boot and by "Check again").
    var podReachable = false
    var podInfo: NicotinePodInfo?
    var checkingPod = false

    /// "Restoring saved settings…" while homepod-config.sh runs.
    var settingsBusy: String?
    /// The script's last line, shown under the buttons.
    var settingsMessage: String?
    var settingsFailed = false

    /// How the running pod starts ("wait in DFU every time it gets power"),
    /// from its startup.cgi. nil until it has been asked, and for a Nicotine
    /// build before 117, which has no such switch.
    var startup: NicotineStartup.Status?
    /// "Switching on…" while a change or a restart into DFU is under way.
    var startupBusy: String?
    var startupMessage: String?
    var startupFailed = false

    /// "Checking and installing the payload…" while an import runs.
    var importBusy = false
    var importMessage: String?
    var importFailed = false

    /// "Building the release boot loaders…" while ReleaseIBootBuilder runs.
    var prepareBusy = false
    var prepareMessage: String?
    var prepareFailed = false

    var isBusy: Bool { stage == .booting || stage == .waitingForPod || prepareBusy }

    var stageTitle: String {
        switch stage {
        case .idle: return "Ready"
        case .booting: return "Sending the boot files…"
        case .waitingForPod: return "Nicotine is starting — waiting for its USB network…"
        case .up: return "Nicotine is running"
        case .failed: return "The boot didn't finish"
        }
    }
}

@MainActor
extension AppModel {

    // MARK: Payload (where the boot files come from)

    /// The payload in use: the picked folder, else the one inside the app,
    /// else an imported one. nil when this Mac has none at all.
    var nicotinePayload: NicotinePayload? {
        NicotinePayloadLocator.current(chosenPath: nicotineFolderPath)
    }

    /// The folder of the payload in use.
    var nicotineLayout: NicotineLayout? { nicotinePayload?.layout }

    func setNicotineFolder(_ url: URL) {
        nicotineFolderPath = url.path
    }

    /// Forget the picked folder: back to the built-in or imported payload.
    func clearNicotineFolder() {
        nicotineFolderPath = ""
    }

    /// Is there a payload to fall back on when no folder is picked?
    var nicotineHasBuiltInOrImportedPayload: Bool {
        NicotinePayloadLocator.resolve(chosen: nil, bundled: NicotinePayloadLocator.bundledRoot(),
                                       imported: NicotinePayloadLocator.importedRoot) != nil
    }

    // MARK: Release boot loaders (from Apple's own files)

    /// Where the release iBSS/iBEC for the payload in use live. A folder the
    /// user picked keeps them in its own `release-iboot/` (so the plain
    /// boot-linux.sh finds them too); a bundled or imported payload can't be
    /// written into, so they go to Application Support.
    var nicotineReleaseIBootDir: URL? {
        guard let payload = nicotinePayload else { return nil }
        switch payload.source {
        case .chosen: return payload.layout.releaseIBootDir
        case .bundled, .imported:
            return AppPaths.support.appendingPathComponent("Nicotine Release iBoot", isDirectory: true)
        }
    }

    /// The two release boot loaders are prepared and ready to boot from.
    var nicotineHasReleaseIBoot: Bool {
        guard let dir = nicotineReleaseIBootDir else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("iBSS.img4").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("iBEC.img4").path)
    }

    /// Do the boot loaders on this Mac still make Apple's upside-down check
    /// (a pod that is upside down when Nicotine is booted goes back to DFU)?
    /// They do if they were built before the app took it out (IBootFlipCheck in
    /// the core); a rebuild fixes that. nil when there are none yet, or the
    /// place can't be found in them.
    var nicotineBootLoadersCheckOrientation: Bool? {
        guard let pair = nicotineReleaseIBootPair else { return nil }
        return IBootFlipCheck.isPresent(inFileAt: pair.iBEC)
    }

    /// The release pair to boot from, or nil when they aren't built yet. The app
    /// boots ONLY on these; the dev loaders are never sent.
    var nicotineReleaseIBootPair: (iBSS: URL, iBEC: URL)? {
        guard nicotineHasReleaseIBoot, let dir = nicotineReleaseIBootDir else { return nil }
        return (dir.appendingPathComponent("iBSS.img4"), dir.appendingPathComponent("iBEC.img4"))
    }

    /// The tools the in-app builder needs: gaster + img4tool (located like every
    /// other tool), hBootPatcher + img4 (bundled in Resources/bin by a
    /// BUNDLE_TOOLS build), and the generic A8 APTicket in Resources.
    private func nicotineReleaseTools() -> ReleaseIBootBuilder.Tools? {
        let fm = FileManager.default
        func helper(_ name: String) -> URL? {
            if let dir = ToolLocator.bundledToolsDirectory {
                let u = dir.appendingPathComponent(name); if fm.isExecutableFile(atPath: u.path) { return u }
            }
            let user = ToolLocator.userToolsDirectory.appendingPathComponent(name)
            if fm.isExecutableFile(atPath: user.path) { return user }
            for pth in ToolEnvironment.searchPaths {
                let u = URL(fileURLWithPath: pth).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: u.path) { return u }
            }
            return nil
        }
        guard let gaster = nicotineTool(.gaster),
              let hb = helper("hBootPatcher"),
              let im4m = Bundle.main.resourceURL?.appendingPathComponent("nicotine-0x7000.im4m"),
              fm.fileExists(atPath: im4m.path) else { return nil }
        return .init(gaster: gaster, hBootPatcher: hb, im4m: im4m)
    }

    /// Which of the builder's pieces this copy of the app lacks, by name
    /// ("hBootPatcher, img4"). Empty when everything is there.
    private func nicotineReleaseToolsMissingNames() -> [String] {
        let fm = FileManager.default
        func has(_ name: String) -> Bool {
            var dirs: [URL] = []
            if let d = ToolLocator.bundledToolsDirectory { dirs.append(d) }
            dirs.append(ToolLocator.userToolsDirectory)
            dirs += ToolEnvironment.searchPaths.map { URL(fileURLWithPath: $0) }
            return dirs.contains { fm.isExecutableFile(atPath: $0.appendingPathComponent(name).path) }
        }
        var missing: [String] = []
        if nicotineTool(.gaster) == nil { missing.append("gaster") }
        if !has("hBootPatcher") { missing.append("hBootPatcher") }
        if let res = Bundle.main.resourceURL,
           fm.fileExists(atPath: res.appendingPathComponent("nicotine-0x7000.im4m").path) {
        } else { missing.append("nicotine-0x7000.im4m") }
        return missing
    }

    /// The builder's tools that this app is missing (for the prepare blocker).
    var nicotineReleaseToolsMissing: Bool { nicotineReleaseTools() == nil }

    /// Why the release boot loaders can't be prepared right now, in the user's
    /// words; nil when preparation can start. (The script needs the pod in DFU
    /// and does its own checkm8, so the same single-HomePod rule as the boot.)
    func nicotinePrepareBlocker() -> String? {
        if nicotineReleaseIBootDir == nil {
            return "Choose or import a Nicotine payload first — the release boot loaders are kept next to it."
        }
        if nicotineReleaseToolsMissing {
            let names = nicotineReleaseToolsMissingNames().joined(separator: ", ")
            return "This copy of HomePod Hospital is missing: \(names). Rebuild it with BUNDLE_TOOLS=1 ./scripts/build-app.sh and check the build output for a WARNING about these."
        }
        if nicotine.prepareBusy { return "Preparation is already running." }
        if nicotine.isBusy { return "Wait for the current boot to finish first." }
        if runningJobCount > 0 { return "Wait for the running restore to finish first." }
        if syscfg?.running == true || diag?.running == true || fullDiag?.running == true {
            return "Another boot is in progress. Let it finish first."
        }
        let dfu = devices.filter { $0.mode == .dfu }
        if dfu.isEmpty { return DFUInstructions.short(then: "Build release boot loaders") }
        if devices.count > 1 { return "Connect only the one HomePod. This step can't choose between several." }
        if let ib = dfu[0].iboot, let why = A8BoardGate.bootBlocker(ib) { return why }
        return nil
    }

    /// Build the release boot loaders in-app (ReleaseIBootBuilder). Streams
    /// its output into the boot log; on success the "Boot with Apple release
    /// loaders" option turns on by itself.
    func prepareNicotineReleaseIBoot() {
        guard !nicotine.prepareBusy, !nicotine.isBusy else { return }
        if let why = nicotinePrepareBlocker() {
            nicotine.prepareFailed = true
            nicotine.prepareMessage = why
            return
        }
        guard let dir = nicotineReleaseIBootDir, let tools = nicotineReleaseTools() else { return }
        nicotine.prepareBusy = true
        nicotine.prepareFailed = false
        nicotine.prepareMessage = nil
        appendNicotineLog("Building the release boot loaders into \(dir.path)")
        appendNicotineLog("(Downloads iBSS/iBEC from Apple's audioOS 16.4, decrypts them on this HomePod, patches and signs them — all with tools inside the app.)")

        let builder = ReleaseIBootBuilder(outputDir: dir, tools: tools)
        nicotinePrepareTask?.cancel()
        nicotinePrepareTask = Task { [weak self] in
            var message = ""
            var failed = false
            do {
                _ = try await builder.run(onLog: { line in Task { @MainActor in self?.appendNicotineLog("  " + line) } })
                message = "Release boot loaders are ready. Boot Nicotine now."
            } catch {
                failed = true
                message = error.localizedDescription
            }
            let text = message, bad = failed
            await MainActor.run {
                guard let self else { return }
                self.nicotine.prepareBusy = false
                self.nicotine.prepareFailed = bad
                self.nicotine.prepareMessage = text
            }
        }
    }

    func cancelNicotinePrepare() { nicotinePrepareTask?.cancel() }

    /// The settings script of the payload in use, pointed at the right backup folder.
    var nicotineSettingsRunner: NicotineSettings? {
        guard let payload = nicotinePayload, payload.layout.hasConfigScript else { return nil }
        return NicotineSettings(layout: payload.layout, configDirectory: payload.configDirectoryOverride())
    }

    /// Verify a payload folder or .zip and install it into Application Support.
    func importNicotinePayload(from url: URL) {
        guard !nicotine.importBusy, !nicotine.isBusy else { return }
        nicotine.importBusy = true
        nicotine.importMessage = nil
        nicotine.importFailed = false
        Task { [weak self] in
            var message = ""
            var failed = false
            do {
                let manifest = try await NicotinePayloadImporter.install(from: url)
                message = "Imported Nicotine \(manifest.summary)."
            } catch {
                failed = true
                message = error.localizedDescription
            }
            let text = message
            let bad = failed
            await MainActor.run {
                guard var st = self?.nicotine else { return }
                st.importBusy = false
                st.importFailed = bad
                st.importMessage = text
                self?.nicotine = st
            }
        }
    }

    // MARK: Tools

    /// gaster and irecovery, found the same way the Factory DIAGS boot finds
    /// them: inside the app first, then the app's own tools folder, then the
    /// Homebrew paths (ToolLocator), then a local SSHRD_Script checkout.
    private func nicotineTool(_ tool: Tool) -> URL? {
        ToolLocator.locate(tool)?.url ?? SSHRDLayout.discover()?.tool(tool.rawValue, fallback: nil)
    }

    private func nicotineTools() -> (gaster: URL, irecovery: URL)? {
        guard let g = nicotineTool(.gaster), let ir = nicotineTool(.irecovery) else { return nil }
        return (g, ir)
    }

    /// The tools the boot needs that this Mac doesn't have yet ("gaster", "irecovery").
    var nicotineMissingTools: [String] {
        [Tool.gaster, Tool.irecovery].filter { nicotineTool($0) == nil }.map(\.rawValue)
    }

    /// Open the app's tool installer (the same one Setup offers).
    func installNicotineTools() {
        openInstaller(builder: false)
    }

    /// Why the boot can't start right now, in the user's words; nil when it can.
    ///
    /// The script's commands don't name a device (plain `gaster` / `irecovery`
    /// act on the first one they find), so this mode insists on exactly one
    /// HomePod on USB and nothing else running.
    func nicotineBlocker() -> String? {
        guard let payload = nicotinePayload else {
            return "This copy of HomePod Hospital has no Nicotine payload inside. Import one, or choose a Nicotine image folder."
        }
        let layout = payload.layout
        guard layout.folderExists else { return "The Nicotine image folder isn't there any more. Choose it again." }
        let missing = layout.missingBootFiles
        if !missing.isEmpty { return "The Nicotine payload is missing: " + missing.joined(separator: ", ") }
        let tools = nicotineMissingTools
        if !tools.isEmpty {
            return tools.joined(separator: " and ") + (tools.count == 1 ? " isn't" : " aren't")
                + " installed on this Mac yet. Click \"Install tools…\" below, let it finish, then come back."
        }
        if nicotine.importBusy { return "Wait for the payload import to finish." }
        if runningJobCount > 0 { return "Wait for the running restore to finish first." }
        if syscfg?.running == true || diag?.running == true || fullDiag?.running == true {
            return "Another boot is in progress. Let it finish first."
        }
        let dfu = devices.filter { $0.mode == .dfu }
        if dfu.isEmpty { return DFUInstructions.short(then: "Boot Nicotine") }
        if devices.count > 1 { return "Connect only the one HomePod you want to boot. This boot can't choose between several." }
        // (Not while a boot of ours is running: a pod passing through its first stage looks the same.)
        if !nicotine.isBusy && dfu[0].isBootLoaderDFU { return DFUInstructions.fromBootLoaderDFU }
        if let ib = dfu[0].iboot, let why = A8BoardGate.bootBlocker(ib) { return why }
        if !nicotineHasReleaseIBoot {
            return "Build the boot loaders first: open the \"Boot loaders\" card below and click \"Build release boot loaders\". It's a one-time step per Mac."
        }
        return nil
    }

    // MARK: Boot

    /// Boot the HomePod in DFU into Nicotine. `reveal` switches the window to
    /// the Nicotine page (used by the device card, which has no room for the log).
    func bootNicotine(reveal: Bool = false) {
        if reveal { nicotineRevealToken += 1 }
        guard !nicotine.isBusy else { return }

        if let why = nicotineBlocker() {
            var st = NicotineUIState()
            st.stage = .failed
            st.error = why
            st.podReachable = nicotine.podReachable
            st.podInfo = nicotine.podInfo
            nicotine = st
            return
        }
        guard let payload = nicotinePayload, let tools = nicotineTools() else { return }
        let layout = payload.layout

        var st = NicotineUIState()
        st.stage = .booting
        st.log = ["Booting Nicotine from \(layout.root.path) (\(payload.source.title.lowercased()))"]
        if nicotineBootLoadersCheckOrientation != false {
            // Boot loaders that still make the upside-down check (built before the app took it out).
            st.log.insert("If the HomePod is still upside down from DFU, turn it right-side up now.", at: 0)
        }
        if let manifest = payload.manifest {
            st.log.append("Payload: \(manifest.summary). Checking its \(manifest.entries.count) files against the MANIFEST first.")
        }
        st.log.append("Boot loaders: Apple release (built from audioOS 16.4).")
        st.importMessage = nicotine.importMessage
        st.importFailed = nicotine.importFailed
        nicotine = st

        let booter = NicotineBooter(config: .init(layout: layout, gaster: tools.gaster, irecovery: tools.irecovery,
                                                  releaseIBoot: nicotineReleaseIBootPair))
        let pod = NicotinePod()
        nicotineTask?.cancel()
        nicotineTask = Task { [weak self] in
            do {
                try await booter.boot(onLog: { line in Task { @MainActor in self?.appendNicotineLog(line) } })
            } catch {
                let cancelled = error is CancellationError
                let message = error.localizedDescription
                let issue = (error as? NicotineError)?.issue
                await MainActor.run {
                    guard var st = self?.nicotine else { return }
                    if cancelled {
                        st.stage = .idle
                        st.log.append("Stopped.")
                    } else {
                        st.stage = .failed
                        st.error = message
                        st.issue = issue
                    }
                    self?.nicotine = st
                }
                return
            }

            await MainActor.run {
                self?.nicotine.stage = .waitingForPod
                self?.appendNicotineLog("Waiting for the pod's USB network (\(NicotinePod.usbAddress))…")
            }
            let up = await pod.waitUntilReachable(timeoutSeconds: 120)
            if Task.isCancelled {
                await MainActor.run {
                    self?.nicotine.stage = .idle
                    self?.appendNicotineLog("Stopped waiting. The HomePod may still be starting.")
                }
                return
            }
            guard up else {
                await MainActor.run {
                    guard var st = self?.nicotine else { return }
                    st.stage = .failed
                    st.issue = ErrorCatalog.nicotineIssue("nicotine.nonetwork")
                    st.error = "Nothing answered at \(NicotinePod.usbAddress) within two minutes."
                    self?.nicotine = st
                }
                return
            }
            let info = try? await pod.info()
            let startup = try? await NicotineStartup().status()
            await MainActor.run {
                guard var st = self?.nicotine else { return }
                st.stage = .up
                st.podReachable = true
                st.podInfo = info
                st.startup = startup
                st.log.append("The pod is up: \(info?.versionLine ?? "web UI answers at \(NicotinePod.usbAddress)").")
                self?.nicotine = st
                self?.autoRestoreNicotineSettingsIfWanted()
            }
        }
    }

    /// After a boot: put this pod's saved settings back, if the option is on
    /// and there is anything saved. A Mac with no backup yet does nothing here.
    private func autoRestoreNicotineSettingsIfWanted() {
        let runner = nicotineSettingsRunner
        guard NicotineSettings.shouldAutoRestore(enabled: nicotineAutoRestore, hasScript: runner != nil,
                                                 backups: runner?.savedBackups ?? []) else {
            if nicotineAutoRestore { appendNicotineLog("No saved settings on this Mac yet. Join WiFi in the web UI, then click \"Save settings\".") }
            return
        }
        appendNicotineLog("Putting the saved settings back (automatic).")
        // --auto: a pod that has already put back the settings it keeps on its own
        // flash (Nicotine build 117) keeps those; an older one gets the backup as before.
        runNicotineSettings(.autoRestore(waitSeconds: 30), automatic: true)
    }

    /// Stop a boot that is under way (also stops the wait for the network).
    func cancelNicotineBoot() {
        nicotineTask?.cancel()
    }

    func appendNicotineLog(_ line: String) {
        nicotine.log.append(line)
        if nicotine.log.count > 400 { nicotine.log.removeFirst(nicotine.log.count - 400) }
    }

    // MARK: The running pod

    /// Is a Nicotine pod answering on USB right now, and which build is it?
    /// Works whether or not this app booted it.
    func refreshNicotinePod() {
        guard !nicotine.checkingPod, !nicotine.isBusy else { return }
        nicotine.checkingPod = true
        let pod = NicotinePod()
        Task { [weak self] in
            let reachable = await pod.isReachable()
            let info: NicotinePodInfo? = reachable ? (try? await pod.info()) : nil
            let startup: NicotineStartup.Status? = reachable ? (try? await NicotineStartup().status()) : nil
            await MainActor.run {
                guard var st = self?.nicotine else { return }
                st.checkingPod = false
                st.podReachable = reachable
                st.podInfo = info
                st.startup = startup
                if reachable && st.stage == .idle { st.stage = .up }
                if !reachable && st.stage == .up { st.stage = .idle }
                self?.nicotine = st
            }
        }
    }

    func openNicotineWebUI() {
        NSWorkspace.shared.open(NicotinePod.webUI)
    }

    // MARK: Starting in DFU (the pod's startup.cgi, Nicotine build 117)

    /// Copies of pods' first boot loaders, made before "wait in DFU" is switched
    /// on. They are Apple's files, each signed for one pod: private, like the backups.
    var nicotineBootLoaderCopies: URL {
        AppPaths.support.appendingPathComponent("Boot Loader Copies", isDirectory: true)
    }

    /// Make the running pod wait in DFU every time it gets power, or undo that.
    /// With it on, the pod never has to be turned over to boot Nicotine; it
    /// can't start audioOS by itself until this is switched off again.
    func setNicotineDFUAtPowerUp(_ on: Bool) {
        guard nicotine.startupBusy == nil else { return }
        nicotine.startupBusy = on ? "Switching on…" : "Switching off…"
        nicotine.startupMessage = nil
        nicotine.startupFailed = false
        appendNicotineLog(on ? "Making the HomePod wait in DFU every time it gets power."
                             : "Letting the HomePod start by itself again.")
        let startup = NicotineStartup()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let copy = nicotineBootLoaderCopies.appendingPathComponent("llb-\(stamp).img4")
        Task { [weak self] in
            // The switch rewrites the pod's first boot loader, which takes about half
            // a second. Keep what is there now: if the power fails in that half
            // second, this copy (or a restore) puts it back.
            var copied = false
            if on {
                do { try await startup.saveLLB(to: copy); copied = true } catch { copied = false }
            }
            var status: NicotineStartup.Status?
            var failure: String?
            do { status = try await startup.setDFUAtPowerUp(on) } catch { failure = error.localizedDescription }
            let didCopy = copied, newStatus = status, why = failure
            await MainActor.run {
                guard var st = self?.nicotine else { return }
                st.startupBusy = nil
                if let newStatus {
                    st.startup = newStatus
                    st.startupFailed = false
                    st.startupMessage = newStatus.dfu == .on
                        ? "On. From now on this HomePod waits in DFU whenever it gets power."
                        : "Off. This HomePod starts by itself again."
                    if didCopy { st.log.append("A copy of its first boot loader is in \(copy.path). Keep it private.") }
                } else {
                    st.startupFailed = true
                    st.startupMessage = why ?? "The HomePod didn't answer."
                }
                self?.nicotine = st
            }
        }
    }

    /// Put the running pod into DFU now, without unplugging it or turning it
    /// over. Nicotine stops (it runs from memory); the pod shows up in DFU mode
    /// a few seconds later, ready for a boot or a restore.
    func restartNicotineIntoDFU() {
        guard nicotine.startupBusy == nil else { return }
        nicotine.startupBusy = "Restarting into DFU…"
        nicotine.startupMessage = nil
        nicotine.startupFailed = false
        appendNicotineLog("Restarting the HomePod into DFU.")
        Task { [weak self] in
            var failure: String?
            do { try await NicotineStartup().restart(intoDFU: true) } catch { failure = error.localizedDescription }
            let why = failure
            await MainActor.run {
                guard var st = self?.nicotine else { return }
                st.startupBusy = nil
                if let why {
                    st.startupFailed = true
                    st.startupMessage = why
                } else {
                    st.startupFailed = false
                    st.startupMessage = nil
                    st.log.append("The HomePod is going to DFU. It shows up in DFU mode in a few seconds.")
                    st.podReachable = false
                    st.podInfo = nil
                    st.startup = nil
                    if st.stage == .up { st.stage = .idle }
                }
                self?.nicotine = st
            }
        }
    }

    // MARK: Saved settings (homepod-config.sh in the payload)

    /// Put the pod's saved settings back (`homepod-config.sh restore --wait 30`).
    func restoreNicotineSettings() { runNicotineSettings(.restore(waitSeconds: 30)) }

    /// Save the pod's current settings to the Mac (`homepod-config.sh save`).
    func saveNicotineSettings() { runNicotineSettings(.save) }

    private func runNicotineSettings(_ action: NicotineSettings.Action, automatic: Bool = false) {
        guard nicotine.settingsBusy == nil else { return }
        guard let settings = nicotineSettingsRunner else {
            nicotine.settingsFailed = true
            nicotine.settingsMessage = "homepod-config.sh isn't in the Nicotine payload, so settings can't be saved or restored from here."
            return
        }
        nicotine.settingsBusy = action.title + "…"
        nicotine.settingsMessage = nil
        nicotine.settingsFailed = false
        appendNicotineLog("$ homepod-config.sh " + action.arguments.joined(separator: " ")
                          + "   (backups in \(settings.backupDirectory.path))")

        nicotineSettingsTask?.cancel()
        nicotineSettingsTask = Task { [weak self] in
            var outcome = NicotineSettings.Outcome.failed("The settings script failed.")
            do {
                let result = try await settings.run(action, onLog: { line in Task { @MainActor in self?.appendNicotineLog("  " + line) } })
                outcome = NicotineSettings.outcome(of: action, exitCode: result.exitCode, output: result.output)
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            let final = outcome
            await MainActor.run {
                guard var st = self?.nicotine else { return }
                st.settingsBusy = nil
                switch final {
                case .done(let text):
                    st.settingsFailed = false
                    st.settingsMessage = NicotineSettings.doneMessage(text, automatic: automatic)
                case .nothingToRestore:
                    st.settingsFailed = false
                    st.settingsMessage = "No saved settings for this HomePod yet. Set it up in the web UI, then click \"Save settings\"."
                case .partial(let text):
                    st.settingsFailed = true
                    st.settingsMessage = text
                case .failed(let text):
                    st.settingsFailed = true
                    st.settingsMessage = text
                }
                self?.nicotine = st
            }
        }
    }
}

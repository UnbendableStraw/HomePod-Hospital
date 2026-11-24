import SwiftUI
import AppKit
import HomePodRestoreCore

/// Boot a HomePod into Nicotine (Linux) and look after it once it is up:
/// open its web UI, put its saved settings back, save them again.
/// The model side is AppModelNicotine.swift; background in docs/nicotine-boot.md.
struct NicotineView: View {
    @EnvironmentObject var model: AppModel

    private var state: NicotineUIState { model.nicotine }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Nicotine",
                           subtitle: "Boot a 1st-gen HomePod into Nicotine, the Linux system that makes it a standalone AirPlay and Bluetooth speaker.")
                VStack(alignment: .leading, spacing: 16) {
                    Banner(icon: "bolt.horizontal.circle.fill",
                           text: "Nicotine runs from memory and changes nothing on the HomePod. It has to be booted again from this Mac after every power cut.",
                           tint: .blue)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    guideCard
                    payloadCard
                    bootCard
                    loadersCard
                    if state.stage == .failed, let error = state.error { errorCard(error) }
                    podCard
                    if !state.log.isEmpty { logCard }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        // A pod booted earlier (or from Terminal) is found when the page opens.
        .task { model.refreshNicotinePod() }
    }

    // MARK: first-run guide

    private var guideCard: some View {
        Card {
            DisclosureGroup("First time? How this works") {
                VStack(alignment: .leading, spacing: 6) {
                    guideStep(1, "Attach the USB adapter to the debug port under the rubber base and plug its cable into this Mac. Leave the HomePod's power unplugged.")
                    guideStep(2, "Turn the HomePod upside down, then plug in power. Order matters: USB first, then power. Wait until the Boot card below stops asking for a HomePod in DFU mode.")
                    guideStep(3, "Turn the HomePod right-side up, then click Boot Nicotine. The boot files go across in a few seconds. (\"Show me how\" next to the button walks through it.)")
                    guideStep(4, "After 30 to 40 seconds the HomePod answers at \(NicotinePod.usbAddress) over the USB cable and \"Open web UI\" appears below.")
                    guideStep(5, "First thing to do there: join your WiFi in the web UI's WiFi tab. The Nicotine image that comes with the app knows no network. After that the HomePod shows up as an AirPlay speaker.")
                    guideStep(6, "Click \"Save settings\" once it is set up. The HomePod forgets everything when it loses power; this Mac puts the settings back after the next boot.")
                    Text("Nothing is written to the HomePod: Nicotine runs from memory, and unplugging power brings back whatever was on it before. It has to be booted from a Mac again after every power cut.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            }
            .font(.headline)
        }
    }

    private func guideStep(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: payload (where the boot files come from)

    private var payloadCard: some View {
        Card {
            Label("Nicotine payload", systemImage: "shippingbox").font(.headline)
            if let payload = model.nicotinePayload {
                let layout = payload.layout
                Text(payloadTitle(payload)).font(.callout.weight(.medium))
                Text(layout.root.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !layout.folderExists {
                    Label("This folder doesn't exist any more.", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red).font(.callout)
                } else if layout.missingBootFiles.isEmpty {
                    Label(payloadReadyText(payload), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("Missing from this payload:", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                    ForEach(layout.missingBootFiles, id: \.self) { name in
                        Text(name).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("This copy of HomePod Hospital was built without a Nicotine payload, and none has been imported on this Mac. Import one (a Nicotine-….zip or its unpacked folder), or choose a Nicotine image folder if you build Nicotine yourself.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Import Nicotine payload…") { importPayload() }
                    .disabled(state.importBusy || state.isBusy)
                Button("Choose a folder…") { chooseFolder() }
                if !model.nicotineFolderPath.isEmpty && model.nicotineHasBuiltInOrImportedPayload {
                    Button("Use the built-in payload") { model.clearNicotineFolder() }
                }
                if let layout = model.nicotineLayout, layout.folderExists {
                    Button("Show in Finder") { NSWorkspace.shared.open(layout.root) }
                }
            }
            .controlSize(.small)
            if state.importBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking and installing the payload…").font(.callout)
                }
            } else if let message = state.importMessage {
                Label(message, systemImage: state.importFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(state.importFailed ? Color.orange : Color.green)
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func payloadReadyText(_ payload: NicotinePayload) -> String {
        var text = "All three boot files are there"
        if let image = payload.layout.imageDescription { text += " (Nicotine image: \(image))" }
        text += payload.manifest == nil ? ". This folder has no MANIFEST, so the files aren't checked."
                                        : ". They are checked against the MANIFEST before every boot."
        return text
    }

    private func payloadTitle(_ payload: NicotinePayload) -> String {
        var text = payload.source.title
        if let manifest = payload.manifest { text += ": Nicotine " + manifest.summary }
        return text
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Nicotine image folder"
        panel.message = "The folder that contains boot-linux.sh and an img4 folder."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if let layout = model.nicotineLayout, layout.folderExists { panel.directoryURL = layout.root }
        if panel.runModal() == .OK, let url = panel.url {
            model.setNicotineFolder(url)
        }
    }

    private func importPayload() {
        let panel = NSOpenPanel()
        panel.title = "Import a Nicotine payload"
        panel.message = "Choose a Nicotine payload: the .zip, or the unpacked folder with MANIFEST inside."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            model.importNicotinePayload(from: url)
        }
    }

    // MARK: boot

    private var bootCard: some View {
        Card {
            Label("Boot", systemImage: "power").font(.headline)
            if state.isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(state.stageTitle).font(.callout.weight(.medium))
                    Spacer()
                    Button("Stop") { model.cancelNicotineBoot() }
                        .controlSize(.small)
                }
                Text("This takes about a minute. The HomePod should already be right-side up; if it isn't, turn it over now.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                let blocker = model.nicotineBlocker()
                Text(blocker ?? "Ready. The HomePod in DFU mode will start Nicotine; nothing on it is erased.")
                    .font(.callout)
                    .foregroundStyle(blocker == nil ? Color.primary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.nicotineMissingTools.isEmpty {
                    HStack {
                        Button("Install tools…") { model.installNicotineTools() }
                        Button("Check again") { Task { await model.refreshTools() } }
                    }
                    .controlSize(.small)
                    Text("The boot needs gaster and irecovery. The installer opens in Terminal (the same one as on the Setup page) and takes a few minutes the first time.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button {
                        model.bootNicotine()
                    } label: {
                        Label("Boot Nicotine", systemImage: "play.fill")
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(blocker != nil)
                    DFUGuideButton(action: "Boot Nicotine",
                                   blocker: { _ in model.nicotineBlocker() },
                                   start: { _ in model.bootNicotine() })
                        .controlSize(.large)
                }
                Text("Same steps as boot-linux.sh: gaster unlocks the HomePod, then the bootloaders, the device tree and the Nicotine image are sent with irecovery.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: boot loaders (dev vs Apple release)

    private var loadersCard: some View {
        Card {
            Label("Boot loaders", systemImage: "cpu").font(.headline)
            let ready = model.nicotineHasReleaseIBoot
            if ready {
                Label("Ready. Built from Apple's audioOS 16.4 — this HomePod will boot from them.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let dir = model.nicotineReleaseIBootDir {
                    Text(dir.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if model.nicotineBootLoadersCheckOrientation == true {
                    Text("These were built before the app took Apple's upside-down check out of them: the HomePod has to be right-side up when Nicotine is booted, or it goes back to DFU. Rebuild them once and it boots in any position.")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Nicotine boots on boot loaders built from Apple's own audioOS 16.4 update — downloaded, decrypted on this HomePod, patched and signed, all inside the app. Build them once on this Mac before the first boot.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if state.prepareBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Building the release boot loaders… watch the log below.").font(.callout)
                    Spacer()
                    Button("Stop") { model.cancelNicotinePrepare() }.controlSize(.small)
                }
            } else {
                let blocker = model.nicotinePrepareBlocker()
                HStack {
                    Button(ready ? "Rebuild release boot loaders…" : "Build release boot loaders…") {
                        model.prepareNicotineReleaseIBoot()
                    }
                    .disabled(blocker != nil)
                    if ready, let dir = model.nicotineReleaseIBootDir {
                        Button("Show in Finder") { NSWorkspace.shared.open(dir) }
                    }
                }
                .controlSize(.small)
                if let blocker {
                    Text(blocker).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Needs the HomePod in DFU. It downloads about 1 MB from Apple, unlocks the HomePod and builds the two files — a minute or two. Nothing is written to the HomePod.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let message = state.prepareMessage {
                Label(message, systemImage: state.prepareFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(state.prepareFailed ? Color.orange : Color.green)
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        Card(tint: .red) {
            Label(state.issue?.title ?? "The boot didn't finish", systemImage: "xmark.octagon.fill")
                .font(.headline).foregroundStyle(.red)
            Text(message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let issue = state.issue {
                Text(issue.explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(issue.suggestions.enumerated()), id: \.offset) { _, s in
                    Label(s, systemImage: "arrow.right.circle").font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: the running pod

    private var podCard: some View {
        Card(tint: state.podReachable ? .green : nil) {
            Label("Running HomePod", systemImage: "homepod.fill").font(.headline)
            if state.podReachable {
                Text(state.podInfo?.versionLine ?? "A pod answers at \(NicotinePod.usbAddress).")
                    .font(.callout.weight(.medium))
                Text("Web UI and SSH are at \(NicotinePod.usbAddress) over the USB cable.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button { model.openNicotineWebUI() } label: { Label("Open web UI", systemImage: "safari") }
                        .buttonStyle(.borderedProminent)
                    Button { model.restoreNicotineSettings() } label: { Label("Restore saved settings", systemImage: "arrow.down.doc") }
                        .disabled(state.settingsBusy != nil || !hasSettingsScript)
                    Button { model.saveNicotineSettings() } label: { Label("Save settings", systemImage: "arrow.up.doc") }
                        .disabled(state.settingsBusy != nil || !hasSettingsScript)
                }
                if let busy = state.settingsBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(busy).font(.callout)
                    }
                } else if let message = state.settingsMessage {
                    Label(message, systemImage: state.settingsFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(state.settingsFailed ? Color.orange : Color.green)
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                Text(settingsNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let startup = state.startup {
                    Divider()
                    Label(startup.dfu == .on ? "This HomePod waits in DFU every time it gets power."
                                             : (startup.dfu == .off ? "This HomePod starts by itself when it gets power."
                                                                    : "This HomePod's first boot loader isn't one this switch knows. It may need a restore."),
                          systemImage: startup.dfu == .on ? "bolt.fill" : "bolt.slash")
                        .font(.callout.weight(.medium))
                    HStack {
                        Button { model.setNicotineDFUAtPowerUp(startup.dfu != .on) } label: {
                            Text(startup.dfu == .on ? "Let it start by itself again" : "Wait in DFU at every power-up")
                        }
                        .disabled(!startup.writable || startup.dfu == .unknown || state.startupBusy != nil)
                        Button { model.restartNicotineIntoDFU() } label: { Label("Restart into DFU", systemImage: "arrow.clockwise") }
                            .disabled(!startup.canRestartIntoDFU || state.startupBusy != nil)
                            .help("Puts this HomePod into DFU now, without unplugging it or turning it over. Nicotine stops.")
                    }
                    if let busy = state.startupBusy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(busy).font(.callout)
                        }
                    } else if let message = state.startupMessage {
                        Label(message, systemImage: state.startupFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(state.startupFailed ? Color.orange : Color.green)
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Waiting in DFU at every power-up means the HomePod never has to be turned over: plug it in and click Boot Nicotine. It can't start audioOS by itself until you switch that off again or restore it.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(state.checkingPod ? "Looking for a pod at \(NicotinePod.usbAddress)…"
                                       : "No pod is answering at \(NicotinePod.usbAddress). After a boot it appears here by itself.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button("Check again") { model.refreshNicotinePod() }
                .controlSize(.small)
                .disabled(state.checkingPod || state.isBusy)
            Toggle("Restore saved settings automatically after boot", isOn: $model.nicotineAutoRestore)
                .font(.callout)
                .disabled(!hasSettingsScript)
        }
    }

    private var hasSettingsScript: Bool { model.nicotineSettingsRunner != nil }

    private var settingsNote: String {
        guard let settings = model.nicotineSettingsRunner else {
            return "Saving and restoring settings needs homepod-config.sh in the Nicotine payload."
        }
        let n = settings.savedBackups.count
        let have = n == 0 ? "No backup saved yet." : (n == 1 ? "One backup is saved." : "\(n) backups are saved (one per HomePod).")
        return "From Nicotine build 117 the HomePod keeps WiFi, its AirPlay name, Bluetooth pairings and sound settings itself; an older build forgets them when it loses power. Either way a copy is kept on this Mac in \(settings.backupDirectory.path) (it contains the WiFi key) and is put back after a boot when the HomePod has none of its own. " + have
    }

    // MARK: log

    private var logCard: some View {
        Card {
            HStack {
                Label("Log", systemImage: "text.alignleft").font(.headline)
                Spacer()
                Button("Copy") { model.copyToClipboard(state.log.joined(separator: "\n")) }
                    .controlSize(.small)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(state.log.suffix(200).enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }.padding(8)
                }
                .frame(minHeight: 150, maxHeight: 260)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: state.log.count) { _ in proxy.scrollTo(min(state.log.count, 200) - 1, anchor: .bottom) }
            }
        }
    }
}

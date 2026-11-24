import SwiftUI
import HomePodRestoreCore

// MARK: - The DFU steps, said the same way everywhere
//
// Order (from the bench): HomePod upside down, adapter on it and the adapter's
// USB cable in the Mac, then power. Once the Mac sees it in DFU mode, turn it
// right-side up — BEFORE the restore / boot starts. It stays in DFU when turned
// over; if it were still upside down when it reboots mid-job, it would drop
// back into DFU instead of carrying on.

enum DFUInstructions {
    /// One sentence for status lines and blockers.
    static func short(then action: String) -> String {
        "Put the HomePod in DFU mode: with it upside down, attach the adapter and plug its USB cable into this Mac, then plug in power. Once it shows up in DFU mode, turn it right-side up and click \(action)."
    }

    /// For a pod in its boot loader's own DFU (same USB mode, but the unlock can't work there).
    static let fromBootLoaderDFU = "This HomePod is in its boot loader's DFU, not the chip's own, and it can't be unlocked from there. Unplug its power, turn it upside down with the adapter and USB still connected, and plug power back in. When it shows up in DFU mode again, turn it right-side up."

    /// For a pod that's running or in recovery: how to get it to DFU.
    static let fromRunning = "Unplug the HomePod's power. Turn it upside down with the adapter and USB still connected, and plug power back in. When it shows up here in DFU mode, turn it right-side up."
}

/// "Show me how": a three-step walkthrough that ends by starting the job.
///
/// With `start`, clicking Done on the last step runs it on the HomePod the guide
/// saw in DFU mode (we can't see the pod being turned right-side up, so Done is
/// taken as "it is"). Without `start` (one button for several jobs) Done only
/// closes the guide.
struct DFUGuideButton: View {
    /// What Done starts, e.g. "Restore", "Boot Nicotine".
    let action: String
    /// The USB port of the card this sits on: its HomePod is the one to watch.
    var preferredLocation: UInt32? = nil
    /// Why the job can't start on this HomePod (nil = fine), checked on step 3.
    var blocker: (@MainActor (ConnectedDevice) -> String?)? = nil
    var start: (@MainActor (ConnectedDevice) -> Void)? = nil
    @EnvironmentObject var model: AppModel
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Label("Show me how", systemImage: "questionmark.circle")
        }
        .help(start == nil
              ? "Step by step: putting the HomePod in DFU mode."
              : "Step by step: putting the HomePod in DFU mode. \(action) starts when you click Done at the end.")
        .sheet(isPresented: $showing) {
            DFUGuideSheet(action: action, preferredLocation: preferredLocation, blocker: blocker, start: start)
                .environmentObject(model)
        }
    }
}

// MARK: - Walkthrough

enum DFUGuideStage: Int, CaseIterable {
    case connect, power, rightSideUp

    var shortTitle: String {
        switch self {
        case .connect: return "Connect"
        case .power: return "Power & DFU"
        case .rightSideUp: return "Right-side up"
        }
    }

    var title: String {
        switch self {
        case .connect: return "Connect the adapter, with the HomePod upside down"
        case .power: return "Plug in the power and wait for DFU mode"
        case .rightSideUp: return "Turn the HomePod right-side up"
        }
    }

    var symbol: String {
        switch self {
        case .connect: return "cable.connector"
        case .power: return "powerplug.fill"
        case .rightSideUp: return "arrow.uturn.up.circle"
        }
    }

    /// Where the step's animation starts, and where it ends.
    var startScene: DFUScene {
        switch self {
        case .connect: return DFUScene(upsideDown: false, usb: false, power: false)
        case .power: return DFUScene(upsideDown: true, usb: true, power: false)
        case .rightSideUp: return DFUScene(upsideDown: true, usb: true, power: true)
        }
    }

    var scene: DFUScene {
        switch self {
        case .connect: return DFUScene(upsideDown: true, usb: true, power: false, arrow: true)
        case .power: return DFUScene(upsideDown: true, usb: true, power: true)
        case .rightSideUp: return DFUScene(upsideDown: false, usb: true, power: true, arrow: true)
        }
    }
}

/// What the illustration shows.
struct DFUScene: Equatable {
    var upsideDown = false
    var usb = true
    var power = false
    var arrow = false
}

struct DFUTip: Hashable {
    let title: String
    let detail: String
    init(_ title: String, _ detail: String) { self.title = title; self.detail = detail }
}

/// Why a HomePod may not show up in DFU mode yet, most common first.
enum DFUTroubleshooting {
    static let tips: [DFUTip] = [
        DFUTip("Power went in before USB.",
         "Unplug the power, check the adapter's cable is in the Mac, wait 5 seconds, then plug the power back in."),
        DFUTip("It wasn't upside down when the power went in.",
         "It only starts in DFU mode if it's upside down at that moment. Turn it over and plug the power in again."),
        DFUTip("The adapter isn't sitting flat.",
         "Old adhesive or a tilted adapter misses the pads. Clean the base and press the adapter down evenly."),
        DFUTip("The cable or the port.",
         "Use a port on the Mac itself rather than a hub, and a cable that carries data — some only charge."),
        DFUTip("macOS is waiting for permission.",
         "On Apple silicon Macs, click Allow if macOS asks whether to let the accessory connect."),
        DFUTip("It started normally instead.",
         "If it shows up as running or in recovery mode, it missed DFU. Unplug the power and try again, upside down."),
    ]
}

struct DFUGuideSheet: View {
    let action: String
    let preferredLocation: UInt32?
    let blocker: (@MainActor (ConnectedDevice) -> String?)?
    let start: (@MainActor (ConnectedDevice) -> Void)?
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var stage = DFUGuideStage.connect
    @State private var shown = DFUGuideStage.connect.startScene
    @State private var showTips = false
    /// Bumped on every animation, so a late step from an earlier one is dropped.
    @State private var playID = 0

    private static let spring = Animation.spring(response: 0.9, dampingFraction: 0.8)

    /// The HomePod in DFU mode: the one on this card's USB port if there is
    /// one, else the first.
    private var dfuDevice: ConnectedDevice? {
        let dfu = model.devices.filter { $0.mode == .dfu }
        if let loc = preferredLocation, let d = dfu.first(where: { $0.locationID == loc }) { return d }
        return dfu.first
    }

    /// A HomePod that's connected but not in DFU (it started normally or went
    /// to recovery).
    private var notDFUDevice: ConnectedDevice? {
        guard dfuDevice == nil else { return nil }
        let others = model.devices.filter { $0.mode != .dfu }
        if let loc = preferredLocation { return others.first { $0.locationID == loc } }
        // No card to go by: only recovery mode is telling (a phone that's
        // charging shows up as a running device too).
        return others.first { $0.mode == .recovery }
    }

    /// Found something in DFU, but it isn't a HomePod board we can work on.
    private var dfuProblem: String? { dfuDevice?.iboot.flatMap { A8BoardGate.bootBlocker($0) } }
    private var dfuReady: Bool { dfuDevice != nil && dfuProblem == nil }

    /// Why Done can't start the job (nil = it can).
    private var startProblem: String? {
        guard let d = dfuDevice else {
            return "The HomePod isn't in DFU mode any more (did the power or USB come out?). Go back a step and plug the power in again."
        }
        return dfuProblem ?? blocker?(d)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Put the HomePod in DFU mode").font(.title2.weight(.semibold))
                    Text(start == nil ? "Three steps." : "Three steps, then \(action) starts.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            stepBar

            DFUSceneView(flip: shown.upsideDown ? 1 : 0, plug: shown.power ? 1 : 0,
                         usb: shown.usb, arrow: shown.arrow, arrowDown: stage == .connect,
                         dfu: stage == .connect ? 0 : (dfuReady ? 2 : 1))
                .frame(width: 460, height: 230)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                Label(stage.title, systemImage: stage.symbol).font(.headline)
                switch stage {
                case .connect: connectStep
                case .power: powerStep
                case .rightSideUp: rightSideUpStep
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)

            HStack {
                if stage != .connect {
                    Button("Back") { go(to: DFUGuideStage(rawValue: stage.rawValue - 1) ?? .connect) }
                }
                Button { play(stage) } label: { Label("Replay", systemImage: "arrow.counterclockwise") }
                    .help("Play this step's animation again.")
                Spacer()
                primaryButton
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear { play(.connect) }
        .task(id: stage) {
            // Still nothing after a while on the power step: open the tips.
            guard stage == .power else { return }
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            if stage == .power && !dfuReady { withAnimation { showTips = true } }
        }
    }

    // MARK: Steps

    private var stepBar: some View {
        HStack(spacing: 0) {
            ForEach(DFUGuideStage.allCases, id: \.self) { s in
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(s.rawValue <= stage.rawValue ? Color.accentColor : Color.secondary.opacity(0.2))
                            .frame(width: 22, height: 22)
                        if s.rawValue < stage.rawValue {
                            Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(Color.white)
                        } else {
                            Text("\(s.rawValue + 1)").font(.caption.weight(.bold))
                                .foregroundStyle(s == stage ? Color.white : Color.secondary)
                        }
                    }
                    Text(s.shortTitle).font(.callout)
                        .foregroundStyle(s == stage ? Color.primary : Color.secondary)
                }
                if s != .rightSideUp {
                    Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1).padding(.horizontal, 10)
                }
            }
        }
    }

    @ViewBuilder private var connectStep: some View {
        Text("Turn the HomePod upside down so it rests on its top. Press the USB adapter onto the debug port in its base, and plug the adapter's cable into this Mac — a port on the Mac itself, not an unpowered hub.")
            .fixedSize(horizontal: false, vertical: true)
        Label("Leave the power unplugged for now.", systemImage: "powerplug")
            .font(.callout.weight(.medium)).foregroundStyle(.orange)
        Text("First time? Pry off the rubber base and clean off the adhesive so the adapter sits flat.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var powerStep: some View {
        Text("Keeping it upside down, plug the HomePod's power cord into the wall. Within a few seconds your Mac should see it in DFU mode. The HomePod itself shows nothing — no light, no sound.")
            .fixedSize(horizontal: false, vertical: true)
        dfuStatus
        DisclosureGroup(isExpanded: $showTips) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(DFUTroubleshooting.tips, id: \.title) { tip in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        (Text(tip.title).bold() + Text(" " + tip.detail))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Not showing up? Common reasons").font(.callout)
        }
    }

    @ViewBuilder private var dfuStatus: some View {
        if let d = dfuDevice, let problem = dfuProblem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("Seen on \(d.portLabel).").font(.caption).foregroundStyle(.secondary)
        } else if let d = dfuDevice {
            Label("HomePod found in DFU mode on \(d.portLabel). Click Next.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout.weight(.medium))
        } else if let d = notDFUDevice {
            Label("The HomePod on \(d.portLabel) is \(d.mode == .recovery ? "in recovery mode" : "running normally") — it didn't start in DFU mode. Unplug the power, make sure it's upside down, wait 5 seconds, and plug the power back in.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for a HomePod in DFU mode… (usually under 10 seconds)")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var rightSideUpStep: some View {
        Text("Turn the HomePod back over so it stands on its base. It stays in DFU mode. Keep the adapter, the USB cable and the power connected — the HomePod reboots partway through, and if it were still upside down then, it would drop back into DFU instead of carrying on.")
            .fixedSize(horizontal: false, vertical: true)
        if start != nil {
            if let problem = startProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
            } else {
                Label("The Mac can't see this step. Click Done once it's right-side up, and \(action) starts.",
                      systemImage: "hand.point.right.fill")
                    .font(.callout.weight(.medium))
            }
        } else {
            Label("Click Done once it's right-side up, then choose what to do with it.", systemImage: "hand.point.right.fill")
                .font(.callout.weight(.medium))
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch stage {
        case .connect:
            Button("Next") { go(to: .power) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        case .power:
            Button("Next") { go(to: .rightSideUp) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!dfuReady)
                .help(dfuReady ? "" : "Next unlocks when the Mac sees the HomePod in DFU mode.")
        case .rightSideUp:
            Button(start == nil ? "Done" : "Done — \(action)") {
                if let start, let d = dfuDevice, startProblem == nil { start(d) }
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(start != nil && startProblem != nil)
        }
    }

    // MARK: Animation

    private func go(to s: DFUGuideStage) {
        guard s != stage else { return }
        stage = s
        if s != .power { showTips = false }
        play(s)
    }

    /// Show the step's starting picture, then animate to its end. The connect
    /// step turns the HomePod over first, then the adapter and cable appear.
    private func play(_ s: DFUGuideStage) {
        playID += 1
        let id = playID
        shown = s.startScene
        let target = s.scene
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard playID == id else { return }
            withAnimation(Self.spring) {
                if s == .connect {
                    shown.upsideDown = target.upsideDown
                    shown.arrow = target.arrow
                } else {
                    shown = target
                }
            }
            guard s == .connect else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) {
                guard playID == id else { return }
                withAnimation(.easeInOut(duration: 0.3)) { shown.usb = true }
            }
        }
    }
}

// MARK: - Illustration

/// A side view: the HomePod on a table, the adapter on its base with a USB
/// cable to a Mac, and its power cord to a wall outlet. `flip` (0 upright …
/// 1 upside down) and `plug` (0 out … 1 in) animate.
struct DFUSceneView: View, Animatable {
    var flip: Double
    var plug: Double
    var usb: Bool
    var arrow: Bool
    /// Which way the arrow turns: toward upside down, or back up.
    var arrowDown: Bool
    /// 0 not relevant yet, 1 waiting for DFU, 2 found.
    var dfu: Int

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(flip, plug) }
        set { flip = newValue.first; plug = newValue.second }
    }

    private static let bodyW: CGFloat = 108
    private static let bodyH: CGFloat = 126
    private static let adapterH: CGFloat = 9
    private static let adapterColor = Color(red: 0.95, green: 0.55, blue: 0.15)

    var body: some View {
        Canvas { ctx, size in draw(in: &ctx, size: size) }
            .accessibilityElement()
            .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [flip > 0.5 ? "HomePod upside down" : "HomePod right-side up"]
        if usb { parts.append("adapter and USB cable connected to the Mac") }
        parts.append(plug > 0.5 ? "power plugged in" : "power unplugged")
        if dfu == 2 { parts.append("the Mac shows DFU mode") }
        return parts.joined(separator: ", ")
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize) {
        let w = size.width
        let tableY = size.height - 34
        let W = Self.bodyW, H = Self.bodyH, aH = Self.adapterH
        let cx = w / 2 - 6
        // Upright it stands on the adapter; upside down it rests on its top.
        let cy = tableY - H / 2 - 1 - aH * CGFloat(1 - flip)
        // Turned over toward the viewer: the vertical scale runs 1 → 0 (edge-on)
        // → -1, so its left side stays on the left and no cable crosses it.
        let turned = CGFloat(cos(flip * .pi))
        let squash = abs(turned) < 0.02 ? (turned < 0 ? -0.02 : 0.02) : turned   // never a singular transform
        func world(_ p: CGPoint) -> CGPoint { CGPoint(x: cx + p.x, y: cy + p.y * squash) }
        // Cables lie on the table, never under it.
        func onTable(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: min(p.y, tableY - 3)) }
        let ink = Color.primary

        // Table and wall
        var table = Path()
        table.move(to: CGPoint(x: 16, y: tableY)); table.addLine(to: CGPoint(x: w - 16, y: tableY))
        ctx.stroke(table, with: .color(ink.opacity(0.25)), lineWidth: 2)

        // Wall outlet (left)
        let outlet = CGRect(x: 26, y: tableY - 112, width: 34, height: 50)
        ctx.fill(Path(roundedRect: outlet, cornerRadius: 6), with: .color(ink.opacity(0.10)))
        ctx.stroke(Path(roundedRect: outlet, cornerRadius: 6), with: .color(ink.opacity(0.35)), lineWidth: 1.5)
        for dy in [14.0, 30.0] {
            ctx.fill(Path(roundedRect: CGRect(x: outlet.minX + 9, y: outlet.minY + dy, width: 4, height: 9), cornerRadius: 1), with: .color(ink.opacity(0.5)))
            ctx.fill(Path(roundedRect: CGRect(x: outlet.minX + 21, y: outlet.minY + dy, width: 4, height: 9), cornerRadius: 1), with: .color(ink.opacity(0.5)))
        }

        // Mac (right)
        let mac = CGRect(x: w - 112, y: tableY - 62, width: 96, height: 62)
        var laptop = ctx.resolve(Image(systemName: "laptopcomputer").resizable())
        laptop.shading = .color(ink.opacity(0.75))
        ctx.draw(laptop, in: mac)
        let screenCenter = CGPoint(x: mac.midX, y: mac.minY + mac.height * 0.40)
        switch dfu {
        case 1:
            ctx.draw(Text("waiting…").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary), at: screenCenter)
        case 2:
            ctx.draw(Text("DFU ✓").font(.system(size: 12, weight: .bold)).foregroundColor(.green), at: screenCenter)
        default:
            break
        }
        let usbPort = CGPoint(x: mac.minX + 6, y: tableY - 5)

        // HomePod (drawn in its own rotated frame)
        var pod = ctx
        pod.translateBy(x: cx, y: cy)
        pod.scaleBy(x: 1, y: squash)
        let bodyRect = CGRect(x: -W / 2, y: -H / 2, width: W, height: H)
        let bodyPath = Path(roundedRect: bodyRect, cornerRadius: 34)
        pod.fill(bodyPath, with: .linearGradient(Gradient(colors: [Color(white: 0.42), Color(white: 0.24)]),
                                                startPoint: CGPoint(x: -W / 2, y: 0), endPoint: CGPoint(x: W / 2, y: 0)))
        var mesh = pod
        mesh.clip(to: bodyPath)
        var dots = Path()
        var row = 0
        for y in stride(from: -H / 2 + 14, through: H / 2 - 10, by: 6) {
            let offset: CGFloat = row % 2 == 0 ? 0 : 3
            for x in stride(from: -W / 2 + 4 + offset, through: W / 2 - 4, by: 6) {
                dots.addEllipse(in: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8))
            }
            row += 1
        }
        mesh.fill(dots, with: .color(.white.opacity(0.13)))
        // Top (touch surface) and rubber base
        pod.fill(Path(roundedRect: CGRect(x: -W / 2 + 16, y: -H / 2 + 1, width: W - 32, height: 6), cornerRadius: 3),
                 with: .color(.black.opacity(0.55)))
        pod.fill(Path(roundedRect: CGRect(x: -W / 2 + 20, y: H / 2 - 6, width: W - 40, height: 6), cornerRadius: 3),
                 with: .color(.black.opacity(0.7)))
        if usb {
            pod.fill(Path(roundedRect: CGRect(x: -17, y: H / 2, width: 34, height: aH), cornerRadius: 2),
                     with: .color(Self.adapterColor))
        }

        // USB cable: adapter → Mac
        if usb {
            let start = world(CGPoint(x: 0, y: H / 2 + aH))
            let out = onTable(world(CGPoint(x: 30, y: H / 2 + aH + 46)))
            var cable = Path()
            cable.move(to: start)
            cable.addCurve(to: usbPort, control1: out, control2: CGPoint(x: usbPort.x - 50, y: usbPort.y))
            ctx.stroke(cable, with: .color(ink.opacity(0.55)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }

        // Power cord: base → plug, which slides into the outlet
        let cordStart = world(CGPoint(x: -W / 2 + 26, y: H / 2 - 2))
        let cordOut = onTable(world(CGPoint(x: -W / 2 - 10, y: H / 2 + 30)))
        let unplugged = CGPoint(x: 92, y: tableY - 8)
        let plugged = CGPoint(x: outlet.maxX + 13, y: outlet.midY)
        let p = CGFloat(plug)
        let head = CGPoint(x: unplugged.x + (plugged.x - unplugged.x) * p, y: unplugged.y + (plugged.y - unplugged.y) * p)
        var cord = Path()
        cord.move(to: cordStart)
        cord.addCurve(to: CGPoint(x: head.x + 9, y: head.y), control1: cordOut, control2: CGPoint(x: head.x + 50, y: head.y + 10))
        ctx.stroke(cord, with: .color(ink.opacity(0.55)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        let headRect = CGRect(x: head.x - 9, y: head.y - 7, width: 18, height: 14)
        ctx.fill(Path(roundedRect: headRect, cornerRadius: 3), with: .color(ink.opacity(0.7)))
        for dy in [-3.5, 3.5] {
            var prong = Path()
            prong.move(to: CGPoint(x: headRect.minX, y: head.y + dy)); prong.addLine(to: CGPoint(x: headRect.minX - 6, y: head.y + dy))
            ctx.stroke(prong, with: .color(ink.opacity(0.7)), lineWidth: 2)
        }
        if plug > 0.97 {
            var bolt = ctx.resolve(Image(systemName: "bolt.fill"))
            bolt.shading = .color(.yellow)
            ctx.draw(bolt, at: CGPoint(x: outlet.midX, y: outlet.minY - 12))
        }

        // Turn-over arrow around the HomePod
        if arrow {
            let r = H / 2 + 26
            var arc = Path()
            let from = Angle.degrees(-40), to = Angle.degrees(40)
            arc.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: arrowDown ? from : to,
                       endAngle: arrowDown ? to : from, clockwise: !arrowDown)
            ctx.stroke(arc, with: .color(.accentColor), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            let tipAngle = CGFloat((arrowDown ? to : from).radians)
            let tip = CGPoint(x: cx + r * cos(tipAngle), y: cy + r * sin(tipAngle))
            // Arrowhead points along the arc's direction of travel.
            let dir: CGFloat = arrowDown ? 1 : -1
            let tangent = CGPoint(x: -sin(tipAngle) * dir, y: cos(tipAngle) * dir)
            let normal = CGPoint(x: cos(tipAngle), y: sin(tipAngle))
            var headPath = Path()
            headPath.move(to: CGPoint(x: tip.x + tangent.x * 9, y: tip.y + tangent.y * 9))
            headPath.addLine(to: CGPoint(x: tip.x + normal.x * 6, y: tip.y + normal.y * 6))
            headPath.addLine(to: CGPoint(x: tip.x - normal.x * 6, y: tip.y - normal.y * 6))
            headPath.closeSubpath()
            ctx.fill(headPath, with: .color(.accentColor))
        }
    }
}

import XCTest
@testable import HomePodRestoreCore

/// What Nicotine build 117 changed on the Mac side: the automatic restore that
/// leaves a pod's own settings alone, and telling the two kinds of DFU apart.
final class NicotineBuild117Tests: XCTestCase {
    func testAutoRestoreAction() {
        XCTAssertEqual(NicotineSettings.Action.autoRestore(waitSeconds: 30).arguments, ["restore", "--auto", "--wait", "30"])
        XCTAssertEqual(NicotineSettings.Action.autoRestore(waitSeconds: -4).arguments, ["restore", "--auto", "--wait", "0"])
        XCTAssertEqual(NicotineSettings.Action.restore(waitSeconds: 30).arguments, ["restore", "--wait", "30"], "a restore the user asks for still replaces the pod's settings")
        XCTAssertEqual(NicotineSettings.Action.autoRestore(waitSeconds: 1).title, NicotineSettings.Action.restore(waitSeconds: 1).title)
    }

    func testAutoRestoreOutcomes() {
        let auto = NicotineSettings.Action.autoRestore(waitSeconds: 30)
        // no backup for this pod: not an error, as with a plain restore
        XCTAssertEqual(NicotineSettings.outcome(of: auto, exitCode: 0, output: """
            homepod-config: no backup for pod d838 in /x/config; nothing to restore
            homepod-config: (make one with: ./homepod-config.sh save)
            """), .nothingToRestore)
        // the pod kept its own settings and the Mac's copy was refreshed
        let kept = NicotineSettings.outcome(of: auto, exitCode: 0, output: """
            homepod-config: restoring pod d838 from /x/config/homepod-config-d838.tar.gz ...
                settings=kept
                result=ok
            homepod-config: the pod put its own saved settings back when it started; they were kept
            homepod-config: this pod is using the settings it keeps itself; the copy on this Mac was updated from it
            """)
        XCTAssertEqual(kept, .done("this pod is using the settings it keeps itself; the copy on this Mac was updated from it"))
        // nothing on the pod's flash: the backup went in as before
        XCTAssertEqual(NicotineSettings.outcome(of: auto, exitCode: 0, output: "    audio=applied\nhomepod-config: restored\n"), .done("restored"))
    }

    func testDoneMessage() {
        XCTAssertEqual(NicotineSettings.doneMessage("restored", automatic: true), "Saved settings put back automatically: restored")
        XCTAssertEqual(NicotineSettings.doneMessage("restored", automatic: false), "restored")
        XCTAssertEqual(NicotineSettings.doneMessage("this pod is using the settings it keeps itself; the copy on this Mac was updated from it", automatic: true),
                       "This HomePod put its own saved settings back when it started; the copy on this Mac was updated from it.")
        XCTAssertEqual(NicotineSettings.doneMessage("this pod is using the settings it keeps itself (the copy on this Mac could not be updated)", automatic: true),
                       "This HomePod put its own saved settings back when it started.")
    }

    func testBootLoaderDFU() {
        func device(_ pid: Int, _ serial: String) -> ConnectedDevice {
            ConnectedDevice(locationID: 0x0110_0000, productID: pid, productName: "Apple Mobile Device (DFU Mode)", serial: serial, speed: 2)
        }
        let rom = device(0x1227, "CPID:7000 CPRV:11 CPFM:03 SCEP:01 BDID:38 ECID:001A2B3C4D5E6F70 IBFL:1C SRTG:[iBoot-1992.0.0.1.19]")
        XCTAssertFalse(rom.isBootLoaderDFU)
        XCTAssertEqual(rom.iboot?.isBootROM, true)
        let pwned = device(0x1227, "CPID:7000 CPRV:11 CPFM:03 SCEP:01 BDID:38 ECID:001A2B3C4D5E6F70 IBFL:1C SRTG:[iBoot-1992.0.0.1.19] PWND:[checkm8]")
        XCTAssertFalse(pwned.isBootLoaderDFU)
        let soft = device(0x1227, "SDOM:01 CPID:7000 CPRV:11 CPFM:03 SCEP:01 BDID:38 ECID:001A2B3C4D5E6F70 IBFL:1D")
        XCTAssertTrue(soft.isBootLoaderDFU, "the boot loader's own DFU: same USB id, no SRTG")
        XCTAssertEqual(soft.iboot?.isBootROM, false)
        XCTAssertFalse(device(0x1227, "").isBootLoaderDFU, "an unread serial string is not evidence")
        XCTAssertFalse(device(0x1281, "SDOM:01 CPID:7000 ECID:001A2B3C4D5E6F70 IBFL:1D SRNM:[XXXXXXXXXXXX]").isBootLoaderDFU, "recovery mode is its own thing")
    }
}

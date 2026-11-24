import XCTest
@testable import HomePodRestoreCore

final class TicketVaultTests: XCTestCase {
    private func firmware(_ version: String, _ build: String, signed: Bool, type: String? = nil, prereq: String? = nil) -> IPSWMeFirmware {
        IPSWMeFirmware(identifier: "AudioAccessory1,1", buildid: build, version: version,
                       url: URL(string: "https://example.invalid/\(build).zip")!, filesize: 1, signed: signed,
                       releasedate: nil, prerequisitebuildid: prereq, releasetype: type, sha256sum: nil)
    }

    func testCandidates() {
        let ipsws = [firmware("18.3", "22K557", signed: true), firmware("17.6", "21M71", signed: false)]
        let otas = [firmware("9.9.18.3", "22K557", signed: true),            // same build as the IPSW: once
                    firmware("9.9.13.4.8", "17M61", signed: true),
                    firmware("9.9.26.1", "23J999", signed: true, type: "Beta"),
                    firmware("9.9.18.6", "22M84", signed: true, prereq: "22K557"),   // a delta update
                    firmware("9.9.12.1.3", "16D39", signed: true)]
        let list = TicketVault.candidates(ipsws: ipsws, otas: otas)
        XCTAssertEqual(list.map(\.build), ["22K557", "17M61", "16D39"], "newest first, one per build, no betas, no deltas, signed only")
        XCTAssertEqual(list[0].url.absoluteString, "https://example.invalid/22K557.zip")
        XCTAssertEqual(list[1].version, "13.4.8")
        // 13.4.8 is asked for even when the list no longer has it
        let without = TicketVault.candidates(ipsws: ipsws, otas: [])
        XCTAssertEqual(without.map(\.build), ["22K557", "17M61"])
        XCTAssertEqual(without[1].url, TicketVault.pinned[0].url)
        XCTAssertLessThanOrEqual(TicketVault.candidates(ipsws: (0..<20).map { firmware("18.\($0)", "22K\($0)", signed: true) }, otas: []).count, TicketVault.limit)
    }

    func testNamesAndArguments() {
        let vault = TicketVault(directory: URL(fileURLWithPath: "/tmp/Tickets"), tsschecker: URL(fileURLWithPath: "/bin/tsschecker"))
        let fw = TicketVault.Firmware(version: "13.4.8", build: "17M61", url: URL(string: "https://example.invalid/a.zip")!)
        XCTAssertEqual(TicketVault.ecidName(0x1A2B3C4D5E6F), "00001A2B3C4D5E6F")
        XCTAssertEqual(vault.ticketFile(ecid: 0x1A2B3C4D5E6F, firmware: fw).path, "/tmp/Tickets/00001A2B3C4D5E6F/13.4.8-17M61.shsh2")
        XCTAssertEqual(vault.manifestFile(for: fw).path, "/tmp/Tickets/Manifests/BuildManifest-13.4.8-17M61.plist")
        XCTAssertEqual(vault.arguments(ecid: 0x1A2B3C4D5E6F, manifest: URL(fileURLWithPath: "/m.plist"), output: URL(fileURLWithPath: "/o.part")),
                       ["-d", "AudioAccessory1,1", "-B", "b238aap", "-m", "/m.plist", "-e", "00001A2B3C4D5E6F", "-s/o.part"])
    }

    func testOutcome() {
        XCTAssertEqual(TicketVault.outcome(exitCode: 0, output: "Saved shsh blobs!\n", ticketWritten: true), .saved)
        XCTAssertEqual(TicketVault.outcome(exitCode: 0, output: """
            Status: 94 (This device isn't eligible for the requested build.)
            18.6 22M84 for AudioAccessory1,1 b238aap is NOT signed!
            done
            """, ticketWritten: false), .notSigned)
        XCTAssertEqual(TicketVault.outcome(exitCode: 1, output: "[TSSC] failed to connect\ndone\n", ticketWritten: false), .failed("[TSSC] failed to connect"))
        XCTAssertEqual(TicketVault.outcome(exitCode: 7, output: "", ticketWritten: false), .failed("tsschecker gave no ticket (exit 7)."))
    }

    func testSavedAndMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ticketvault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = TicketVault(directory: dir, tsschecker: URL(fileURLWithPath: "/nonexistent/tsschecker"))
        let a = TicketVault.Firmware(version: "18.3", build: "22K557", url: URL(string: "https://example.invalid/a.zip")!)
        let b = TicketVault.Firmware(version: "13.4.8", build: "17M61", url: URL(string: "https://example.invalid/b.zip")!)
        let ecid: UInt64 = 0xABCDEF
        XCTAssertEqual(vault.missing(ecid: ecid, from: [a, b]), [a, b])
        try FileManager.default.createDirectory(at: vault.folder(ecid: ecid), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 6000).write(to: vault.ticketFile(ecid: ecid, firmware: a))
        try Data(repeating: 1, count: 10).write(to: vault.ticketFile(ecid: ecid, firmware: b))   // a stub is not a ticket
        XCTAssertTrue(vault.hasTicket(ecid: ecid, firmware: a))
        XCTAssertEqual(vault.missing(ecid: ecid, from: [a, b]), [b])
        XCTAssertEqual(vault.savedTickets(ecid: ecid), ["13.4.8-17M61.shsh2", "18.3-22K557.shsh2"])
        XCTAssertEqual(vault.savedTickets(ecid: 1), [])
    }

    func testSaveIsANoOpWhenTheTicketIsThere() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ticketvault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = TicketVault(directory: dir, tsschecker: URL(fileURLWithPath: "/nonexistent/tsschecker"))
        let a = TicketVault.Firmware(version: "18.3", build: "22K557", url: URL(string: "https://example.invalid/a.zip")!)
        try FileManager.default.createDirectory(at: vault.folder(ecid: 5), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 6000).write(to: vault.ticketFile(ecid: 5, firmware: a))
        let outcome = await vault.save(ecid: 5, firmware: a)
        XCTAssertEqual(outcome, .alreadySaved)
        let results = await vault.saveMissing(ecid: 5, firmwares: [a])
        XCTAssertTrue(results.isEmpty)
    }

    func testWhichPodsGetTickets() async {
        func device(_ pid: Int, _ serial: String, at location: UInt32 = 0x0110_0000) -> ConnectedDevice {
            ConnectedDevice(locationID: location, productID: pid, productName: "x", serial: serial, speed: 2)
        }
        let dfu = device(0x1227, "CPID:7000 CPRV:11 CPFM:03 SCEP:01 BDID:38 ECID:001A2B3C4D5E6F70 IBFL:1C SRTG:[iBoot-1992.0.0.1.19]")
        let recovery = device(0x1281, "SDOM:01 CPID:7000 BDID:38 ECID:00AABBCCDDEEFF00 IBFL:1D SRNM:[XXXXXXXXXXXX]", at: 0x0120_0000)
        let devBoard = device(0x1227, "CPID:7000 BDID:39 ECID:0000000000000042 IBFL:1C SRTG:[iBoot-1992.0.0.1.19]", at: 0x0130_0000)
        let phone = device(0x1227, "CPID:8015 BDID:0E ECID:0000000000000043 IBFL:3C SRTG:[iBoot-3332.0.0.1.23]", at: 0x0140_0000)
        let running = device(0x12A8, "0000810100000000000000", at: 0x0150_0000)
        XCTAssertEqual(TicketKeeper.ecids(in: [dfu, recovery, devBoard, phone, running, dfu]), [0x001A2B3C4D5E6F70, 0x00AABBCCDDEEFF00])
        XCTAssertEqual(TicketKeeper.ecids(in: []), [])
        // each pod once per run of the app
        let keeper = TicketKeeper()
        let first = await keeper.claim([1, 2])
        let second = await keeper.claim([2, 3])
        XCTAssertEqual(first, [1, 2])
        XCTAssertEqual(second, [3])
    }

    func testSummary() {
        let a = TicketVault.Firmware(version: "18.3", build: "22K557", url: URL(string: "https://example.invalid/a.zip")!)
        let b = TicketVault.Firmware(version: "13.4.8", build: "17M61", url: URL(string: "https://example.invalid/b.zip")!)
        let c = TicketVault.Firmware(version: "12.1.3", build: "16D39", url: URL(string: "https://example.invalid/c.zip")!)
        XCTAssertNil(TicketVault.summary([]))
        XCTAssertEqual(TicketVault.summary([(a, .saved), (b, .saved)]), "Signing tickets: saved for 18.3, 13.4.8.")
        XCTAssertEqual(TicketVault.summary([(a, .saved), (b, .notSigned), (c, .failed("x"))]),
                       "Signing tickets: saved for 18.3; Apple no longer signs 13.4.8; couldn't get 12.1.3 (will try again next time).")
        XCTAssertNil(TicketVault.summary([(a, .alreadySaved)]))
    }
}

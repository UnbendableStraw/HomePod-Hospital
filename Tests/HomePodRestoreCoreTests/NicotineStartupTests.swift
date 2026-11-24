import XCTest
@testable import HomePodRestoreCore

final class NicotineStartupTests: XCTestCase {
    func testArguments() {
        let s = NicotineStartup()
        XCTAssertEqual(s.arguments(for: .status), ["-s", "-m", "15", "http://172.16.42.1/cgi-bin/startup.cgi?action=status"])
        let on = s.arguments(for: .dfuOn)
        XCTAssertTrue(on.contains("Content-Type: application/x-homepod"), "the pod refuses a state change without it")
        XCTAssertTrue(on.contains("action=dfu_on"))
        XCTAssertEqual(on.last, "http://172.16.42.1/cgi-bin/startup.cgi")
        XCTAssertTrue(s.arguments(for: .restartIntoDFU).contains("action=restart_dfu"))
        XCTAssertFalse(NicotineStartup.Action.status.changesState)
        for a in NicotineStartup.Action.allCases where a != .status { XCTAssertTrue(a.changesState) }
        XCTAssertEqual(NicotineStartup(host: "192.0.2.7").arguments(for: .status).last, "http://192.0.2.7/cgi-bin/startup.cgi?action=status")
    }

    func testParseStatus() throws {
        let on = try NicotineStartup.parseStatus(#"{"ok":true,"available":true,"dfu":"on","writable":true,"backup":"none","can_restart_dfu":true}"# + "\n")
        XCTAssertEqual(on, NicotineStartup.Status(dfu: .on, writable: true, canRestartIntoDFU: true))
        let off = try NicotineStartup.parseStatus(#"{"ok":true,"available":true,"dfu":"off","writable":false,"backup":"matches","can_restart_dfu":false}"#)
        XCTAssertEqual(off, NicotineStartup.Status(dfu: .off, writable: false, canRestartIntoDFU: false))
        XCTAssertEqual(try NicotineStartup.parseStatus(#"{"ok":true,"available":true,"dfu":"unknown","writable":true,"can_restart_dfu":true}"#).dfu, .unknown)
    }

    func testParseStatusFailures() {
        func failure(_ text: String) -> NicotineStartup.Failure? {
            do { _ = try NicotineStartup.parseStatus(text); return nil } catch { return error as? NicotineStartup.Failure }
        }
        XCTAssertEqual(failure(""), .noAnswer)
        XCTAssertEqual(failure("<HTML><HEAD><TITLE>404 Not Found</TITLE></HEAD>"), .notSupported, "a build before 117 has no startup.cgi")
        XCTAssertEqual(failure(#"{"ok":true,"available":false}"#), .notSupported)
        XCTAssertEqual(failure(#"{"ok":false,"error":"this kernel cannot write the LLB"}"#), .refused("this kernel cannot write the LLB"))
        XCTAssertEqual(failure(#"{"ok":true,"available":true,"dfu":"sideways"}"#), .notSupported)
        XCTAssertNotNil(NicotineStartup.Failure.notSupported.errorDescription)
    }

    func testRestartAnswer() throws {
        XCTAssertNoThrow(try NicotineStartup.answer(#"{"ok":true,"restarting":true}"#))
        XCTAssertThrowsError(try NicotineStartup.answer(#"{"ok":false,"error":"a restart is already under way"}"#))
    }

    func testLooksLikeLLB() {
        var img = Data([0x30, 0x83, 0x02, 0xb8, 0xfd, 0x16, 0x04]) + Data("IMG4".utf8) + Data([0x30, 0x83, 0x02, 0xa6, 0x1a, 0x16, 0x04])
            + Data("IM4P".utf8) + Data([0x16, 0x04]) + Data("illb".utf8)
        img.append(Data(repeating: 0xAB, count: 8000))
        XCTAssertTrue(NicotineStartup.looksLikeLLB(img))
        XCTAssertFalse(NicotineStartup.looksLikeLLB(Data(img.prefix(100))), "too short")
        XCTAssertFalse(NicotineStartup.looksLikeLLB(Data(#"{"ok":false,"error":"no working boot loader found on the flash"}"#.utf8)))
        var inverted = img; inverted[0] = 0xCF
        XCTAssertFalse(NicotineStartup.looksLikeLLB(inverted), "the switched-off form is not a copy worth keeping")
        XCTAssertEqual(NicotineStartup().llbArguments(saveTo: URL(fileURLWithPath: "/tmp/x.img4")),
                       ["-s", "-f", "-m", "30", "-o", "/tmp/x.img4", "http://172.16.42.1/cgi-bin/startup.cgi?action=llb"])
    }
}

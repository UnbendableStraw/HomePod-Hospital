import Foundation

/// How a pod running Nicotine starts, and restarting it: the pod's
/// `startup.cgi` (Nicotine build 117 and later; background in nicotine/README.md).
///
/// - "DFU at every power-up": the pod waits in DFU whenever it gets power, so
///   it never has to be turned upside down to boot Nicotine. While it is on,
///   the pod can't start audioOS by itself.
/// - "Restart into DFU": puts the running pod into the chip's own DFU once,
///   without unplugging it.
///
/// curl rather than URLSession, like `NicotinePod`: App Transport Security
/// refuses plain HTTP, and the pod has nothing else.
public struct NicotineStartup: Sendable {
    public enum DFUAtPowerUp: String, Sendable, Equatable {
        case on, off
        /// The first boot loader on the flash is neither a working one nor one
        /// this switch turned off (a write that was cut off, for example).
        case unknown
    }

    public struct Status: Sendable, Equatable {
        public var dfu: DFUAtPowerUp
        /// The pod's kernel can change the switch.
        public var writable: Bool
        public var canRestartIntoDFU: Bool

        public init(dfu: DFUAtPowerUp, writable: Bool, canRestartIntoDFU: Bool) {
            self.dfu = dfu; self.writable = writable; self.canRestartIntoDFU = canRestartIntoDFU
        }
    }

    public enum Action: String, Sendable, Equatable, CaseIterable {
        case status
        case dfuOn = "dfu_on"
        case dfuOff = "dfu_off"
        case restart
        case restartIntoDFU = "restart_dfu"

        /// Everything except reading the state is a POST (the pod refuses a GET).
        public var changesState: Bool { self != .status }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        /// curl got no answer from the pod.
        case noAnswer
        /// The pod answered, but its Nicotine build has no such switch.
        case notSupported
        /// The pod said no; its own words.
        case refused(String)
        /// What came back as the boot loader copy isn't one.
        case notAnLLB

        public var errorDescription: String? {
            switch self {
            case .noAnswer: return "The HomePod didn't answer. Is Nicotine still running, and is the USB cable in?"
            case .notSupported: return "This Nicotine build can't do that yet. It needs build 117 or later."
            case .refused(let why): return why
            case .notAnLLB: return "The HomePod didn't send a usable copy of its boot loader."
            }
        }
    }

    public var host: String
    public var curl: URL

    public init(host: String = NicotinePod.usbAddress, curl: URL = URL(fileURLWithPath: "/usr/bin/curl")) {
        self.host = host; self.curl = curl
    }

    var endpoint: String { "http://\(host)/cgi-bin/startup.cgi" }

    /// The curl arguments for one request. A state change carries the content
    /// type the pod insists on; switching rewrites the boot loader and gets
    /// more time than a plain question.
    public func arguments(for action: Action) -> [String] {
        if action.changesState {
            return ["-s", "-m", "75", "-H", "Content-Type: application/x-homepod", "-H", "Expect:",
                    "--data", "action=\(action.rawValue)", endpoint]
        }
        return ["-s", "-m", "15", endpoint + "?action=\(action.rawValue)"]
    }

    /// Reads the pod's answer to `status`, `dfu_on` or `dfu_off`.
    public static func parseStatus(_ text: String) throws -> Status {
        let object = try answer(text)
        guard object["available"] as? Bool == true else { throw Failure.notSupported }
        guard let raw = object["dfu"] as? String, let dfu = DFUAtPowerUp(rawValue: raw) else { throw Failure.notSupported }
        return Status(dfu: dfu,
                      writable: object["writable"] as? Bool ?? false,
                      canRestartIntoDFU: object["can_restart_dfu"] as? Bool ?? false)
    }

    /// The pod's JSON answer as a dictionary. Anything that isn't JSON (an old
    /// build's "404 Not Found" page) means the pod has no startup.cgi.
    static func answer(_ text: String) throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.noAnswer }
        guard let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.notSupported
        }
        if object["ok"] as? Bool != true {
            throw Failure.refused((object["error"] as? String) ?? "The HomePod refused the request.")
        }
        return object
    }

    private func send(_ action: Action) async throws -> String {
        let runner = ProcessRunner(executable: curl, arguments: arguments(for: action))
        guard let result = try? await runner.run(onLine: { _ in }), result.exitCode == 0 else { throw Failure.noAnswer }
        return result.output
    }

    public func status() async throws -> Status {
        try Self.parseStatus(try await send(.status))
    }

    /// Turns "DFU at every power-up" on or off; the answer is the new state.
    public func setDFUAtPowerUp(_ on: Bool) async throws -> Status {
        try Self.parseStatus(try await send(on ? .dfuOn : .dfuOff))
    }

    /// Restarts the pod. Nicotine is gone afterwards (it runs from memory).
    /// The pod answers first and restarts a second later.
    public func restart(intoDFU: Bool) async throws {
        _ = try Self.answer(try await send(intoDFU ? .restartIntoDFU : .restart))
    }

    // MARK: A copy of the first boot loader

    /// `curl -f` so that an error page is not saved as the file.
    public func llbArguments(saveTo file: URL) -> [String] {
        ["-s", "-f", "-m", "30", "-o", file.path, endpoint + "?action=llb"]
    }

    /// Does this look like the first boot loader (an IMG4 holding an "illb"
    /// payload)? The pod's JSON error answer, for one, does not.
    public static func looksLikeLLB(_ data: Data) -> Bool {
        guard data.count > 4096, data.first == 0x30 else { return false }
        let head = data.prefix(64)
        func has(_ tag: String) -> Bool { head.range(of: Data(tag.utf8)) != nil }
        return has("IMG4") && has("IM4P") && has("illb")
    }

    /// Saves the pod's first boot loader, as it is on the flash, to `file`.
    /// Switching "DFU at every power-up" rewrites that boot loader; this copy
    /// can put it back if the power fails during the half second that takes.
    /// The file is Apple's and signed for this one pod: keep it private.
    public func saveLLB(to file: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let part = file.appendingPathExtension("part")
        try? fm.removeItem(at: part)
        let runner = ProcessRunner(executable: curl, arguments: llbArguments(saveTo: part))
        guard let result = try? await runner.run(onLine: { _ in }), result.exitCode == 0 else {
            try? fm.removeItem(at: part)
            throw Failure.noAnswer
        }
        guard let data = try? Data(contentsOf: part), Self.looksLikeLLB(data) else {
            try? fm.removeItem(at: part)
            throw Failure.notAnLLB
        }
        try? fm.removeItem(at: file)
        try fm.moveItem(at: part, to: file)
    }
}

import AppKit
import Foundation
import Darwin

struct CodexQuotaAccount: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let label: String

    var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Atoll/CodexQuotaAccounts", directoryHint: .isDirectory)
            .appending(path: id.uuidString, directoryHint: .isDirectory)
    }
}

enum CodexQuotaAccountError: LocalizedError {
    case missingCLI, invalidReply, timedOut, browserUnavailable, authorizationFailed

    var errorDescription: String? {
        switch self {
        case .missingCLI: return String(localized: "请安装或更新 Codex CLI，再试一次。")
        case .invalidReply: return String(localized: "Codex 无法完成请求。请检查连接或更新 Codex CLI。")
        case .timedOut: return String(localized: "Codex 请求超时，请重试。")
        case .browserUnavailable: return String(localized: "无法打开授权页面。")
        case .authorizationFailed: return String(localized: "Codex 授权未完成，请重新授权。")
        }
    }
}

enum CodexQuotaAccounts {
    private struct Identity: Decodable {
        struct Account: Decodable {
            let type: String
            let email: String?
            let workspaceName: String?
        }

        let account: Account?

        var label: String? {
            guard let account, account.type == "chatgpt" else { return nil }
            let names = [account.email, account.workspaceName].compactMap { $0 }.filter { !$0.isEmpty }
            return names.isEmpty ? String(localized: "ChatGPT 账号") : names.joined(separator: " · ")
        }
    }

    private struct Rates: Decodable {
        struct Window: Decodable {
            let usedPercent: Double
            let resetsAt: Double?

            var limit: UsageLimit {
                UsageLimit(used: usedPercent, limit: 100, resetsAt: resetsAt.map { Date(timeIntervalSince1970: $0) })
            }
        }

        struct Limits: Decodable {
            let primary: Window?
            let secondary: Window?
        }

        let rateLimits: Limits
    }

    static func authorize(id: UUID = UUID()) async throws -> CodexQuotaAccount {
        let profile = CodexQuotaAccount(id: id, label: "")
        return try await run(in: profile.directory) { connection in
            let reply = try connection.request("account/login/start", params: ["type": "chatgpt"])
            guard let id = reply["loginId"] as? String, let raw = reply["authUrl"] as? String,
                  let url = URL(string: raw), url.scheme == "https", url.host == "auth.openai.com" else {
                throw CodexQuotaAccountError.invalidReply
            }
            guard DispatchQueue.main.sync(execute: { NSWorkspace.shared.open(url) }) else {
                throw CodexQuotaAccountError.browserUnavailable
            }
            let deadline = ContinuousClock.now + .seconds(300)
            let completion = try connection.receive(until: deadline) { message in
                guard message["method"] as? String == "account/login/completed",
                      let params = message["params"] as? [String: Any] else { return false }
                return params["loginId"] as? String == id
            }
            guard let params = completion["params"] as? [String: Any], params["success"] as? Bool == true else {
                throw CodexQuotaAccountError.authorizationFailed
            }
            let identity: Identity = try connection.decode(connection.request("account/read"))
            guard let label = identity.label else { throw CodexQuotaAccountError.authorizationFailed }
            return CodexQuotaAccount(id: profile.id, label: label)
        } onFailure: {
            try? FileManager.default.removeItem(at: profile.directory)
        }
    }

    static func snapshot(for profile: CodexQuotaAccount, now: Date) async throws -> UsageSnapshot {
        try await run(in: profile.directory) { connection in
            let raw = try connection.request("account/rateLimits/read")
            let rates: Rates = try connection.decode(raw)
            var snapshot = UsageSnapshot()
            snapshot.sessionLimit = rates.rateLimits.primary?.limit
            snapshot.weekLimit = rates.rateLimits.secondary?.limit
            if let credits = raw["rateLimitResetCredits"] as? [String: Any] {
                snapshot.codexResetCredits = try? CodexResetCredits.decode(JSONSerialization.data(withJSONObject: credits))
            }
            snapshot.lastUpdated = now
            return snapshot
        }
    }

    private static func run<T: Sendable>(in directory: URL, operation: @escaping @Sendable (CodexQuotaConnection) throws -> T, onFailure: @escaping @Sendable () -> Void = {}) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let result = try withConnection(in: directory, operation: operation)
                    continuation.resume(returning: result)
                } catch {
                    onFailure()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func withConnection<T>(in directory: URL, operation: (CodexQuotaConnection) throws -> T) throws -> T {
        let connection = try CodexQuotaConnection(directory: directory)
        defer { connection.close() }
        return try operation(connection)
    }
}

private final class CodexQuotaConnection {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 0

    init(directory: URL) throws {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.volta/bin"]
        guard let executable = paths.filter({ $0.hasPrefix("/") }).map({ "\($0)/codex" })
            .first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw CodexQuotaAccountError.missingCLI
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var isolated = environment.filter { !$0.key.hasPrefix("CODEX_") && !$0.key.hasPrefix("OPENAI_") }
        isolated["CODEX_HOME"] = directory.path
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://", "-c", "cli_auth_credentials_store=\"file\""]
        process.environment = isolated
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // A disappearing helper must surface as a write error, not terminate Atoll.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            close()
            throw CodexQuotaAccountError.invalidReply
        }
        do {
            _ = try request("initialize", params: ["clientInfo": ["name": "atoll", "version": "1"]])
            try send(["method": "initialized"])
        } catch {
            close()
            throw error
        }
    }

    func close() {
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
    }

    func request(_ method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        nextID += 1
        let id = nextID
        try send(["id": id, "method": method, "params": params])
        let response = try receive(until: .now + .seconds(35)) { $0["id"] as? Int == id }
        guard let result = response["result"] as? [String: Any] else { throw CodexQuotaAccountError.invalidReply }
        return result
    }

    func decode<T: Decodable>(_ result: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: result))
    }

    private func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func receive(until deadline: ContinuousClock.Instant, matching: ([String: Any]) -> Bool) throws -> [String: Any] {
        while ContinuousClock.now < deadline {
            if let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any], matching(message) {
                    return message
                }
                continue
            }

            let descriptor = output.fileHandleForReading.fileDescriptor
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, 250)
            if ready < 0 && errno == EINTR { continue }
            if ready == 0 { continue }
            guard ready > 0, event.revents & Int16(POLLIN) != 0 else { throw CodexQuotaAccountError.invalidReply }
            var bytes = [UInt8](repeating: 0, count: 8_192)
            let length = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if length < 0 && errno == EINTR { continue }
            guard length > 0, buffer.count + length <= 1_048_576 else { throw CodexQuotaAccountError.invalidReply }
            buffer.append(contentsOf: bytes.prefix(length))
        }
        throw CodexQuotaAccountError.timedOut
    }
}

import Foundation
import os

// Codex/ChatGPT rate-limit usage from chatgpt.com/backend-api/wham/usage; request+response shape per OpenUsage.
struct CodexQuotaClient {
    private static let log = os.Logger(subsystem: "com.atoll.DynamicIsland", category: "CodexQuota")
    let session: URLSession
    init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    private struct AuthFile: Decodable {
        struct Tokens: Decodable {
            let accessToken: String
            let accountId: String?
            let idToken: String?

            // This label is display metadata only. The quota service validates the token.
            var email: String? {
                guard var payload = (idToken ?? accessToken).split(separator: ".").dropFirst().first.map(String.init) else { return nil }
                payload = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
                guard let data = Data(base64Encoded: payload), let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                let profile = claims["https://api.openai.com/profile"] as? [String: Any]
                return (claims["email"] as? String) ?? (profile?["email"] as? String)
            }
        }
        let tokens: Tokens
    }

    private struct RateLimitWindow: Decodable {
        let usedPercent: Double
        let resetAt: Double?
        let resetAfterSeconds: Double?
    }

    private struct RateLimit: Decodable {
        let primaryWindow: RateLimitWindow?
        let secondaryWindow: RateLimitWindow?
    }

    private struct UsageResponse: Decodable {
        let rateLimit: RateLimit?
    }

    func fetchLimits() async -> (session: UsageLimit?, week: UsageLimit?, resetCredits: CodexResetCredits?, email: String?) {
        guard let creds = loadCredentials() else {
            Self.log.notice("no credentials: auth.json/Keychain missing or unparseable")
            return (nil, nil, nil, nil)
        }
        let limits = await fetchLimits(using: creds)
        return (limits.session, limits.week, limits.resetCredits, creds.email)
    }

    // Reset detail failures must not hide successfully fetched quota windows.
    private func fetchLimits(using creds: AuthFile.Tokens) async -> (session: UsageLimit?, week: UsageLimit?, resetCredits: CodexResetCredits?) {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Atoll", forHTTPHeaderField: "User-Agent")
        if let accountId = creds.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                Self.log.error("wham/usage HTTP \(code) — \(code == 401 || code == 403 ? "auth/credential" : "request") failure")
                return (nil, nil, nil)
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let now = Date()
            var resets: CodexResetCredits?
            // The usage response includes a count; the dedicated GET includes expiry details.
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let summary = object["rate_limit_reset_credits"] as? [String: Any], let summaryData = try? JSONSerialization.data(withJSONObject: summary) {
                resets = try? CodexResetCredits.decode(summaryData)
            }
            var detailRequest = request
            detailRequest.url = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")
            detailRequest.timeoutInterval = 15
            if let (details, detailResponse) = try? await session.data(for: detailRequest), let detailHTTP = detailResponse as? HTTPURLResponse, (200..<300).contains(detailHTTP.statusCode), let decoded = try? CodexResetCredits.decode(details) {
                resets = decoded
            }
            if let decoded = try? decoder.decode(UsageResponse.self, from: data) {
                let sessionLimit = decoded.rateLimit?.primaryWindow.map { limit(from: $0, now: now) }
                let weekLimit = decoded.rateLimit?.secondaryWindow.map { limit(from: $0, now: now) }
                if sessionLimit != nil || weekLimit != nil { return (sessionLimit, weekLimit, resets) }
            }
            let sessionLimit = headerFallback(http, key: "x-codex-primary-used-percent")
            let weekLimit = headerFallback(http, key: "x-codex-secondary-used-percent")
            if sessionLimit == nil && weekLimit == nil {
                Self.log.error("wham/usage 200 but no usage found — response shape may have changed (\(data.count) bytes)")
            }
            return (sessionLimit, weekLimit, resets)
        } catch {
            Self.log.error("wham/usage request errored: \(error.localizedDescription, privacy: .public)")
            return (nil, nil, nil)
        }
    }

    private func limit(from window: RateLimitWindow, now: Date) -> UsageLimit {
        let resets = window.resetAt.map { Date(timeIntervalSince1970: $0) } ?? window.resetAfterSeconds.map { now.addingTimeInterval($0) }
        return UsageLimit(used: window.usedPercent, limit: 100, resetsAt: resets)
    }

    private func headerFallback(_ http: HTTPURLResponse, key: String) -> UsageLimit? {
        guard let raw = http.value(forHTTPHeaderField: key), let percent = Double(raw) else { return nil }
        return UsageLimit(used: percent, limit: 100)
    }

    // auth.json ($CODEX_HOME, ~/.codex, ~/.config/codex), then Keychain "Codex Auth" holding the same JSON payload.
    private func loadCredentials() -> AuthFile.Tokens? {
        for path in authPaths() {
            if let data = try? Data(contentsOf: path), let creds = parseAuth(data) { return creds }
        }
        guard let value = KeychainReader.genericPassword(service: "Codex Auth"),
              let creds = parseAuth(Data(value.utf8)) else { return nil }
        return creds
    }

    private func authPaths() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHome.isEmpty {
            return [URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")]
        }
        return [
            home.appendingPathComponent(".codex/auth.json"),
            home.appendingPathComponent(".config/codex/auth.json"),
        ]
    }

    private func parseAuth(_ data: Data) -> AuthFile.Tokens? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let parsed = try? decoder.decode(AuthFile.self, from: data) else { return nil }
        return parsed.tokens
    }
}

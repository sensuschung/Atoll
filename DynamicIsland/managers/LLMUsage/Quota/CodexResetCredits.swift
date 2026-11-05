import Foundation

/// Earned resets are separate from the automatic reset dates on quota windows.
struct CodexResetCredits: Decodable, Equatable {
    let availableCount: Int
    var credits: [CodexResetCredit]?

    func availableCredits(at date: Date) -> [CodexResetCredit] {
        (credits ?? []).filter { $0.status == "available" && ($0.expiresAt.map { $0 > date } ?? true) }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }

    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) { return Date(timeIntervalSince1970: seconds) }
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid reset expiry date")
        }
        return try decoder.decode(Self.self, from: data)
    }
}

struct CodexResetCredit: Decodable, Equatable, Identifiable {
    let id: String
    let resetType: String
    let status: String
    let expiresAt: Date?
    let title: String?
    let isSupportedByPlan: Bool?
}

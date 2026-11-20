import Foundation

struct CodexUsageProvider: UsageProvider {
    let id: ProviderID = .codex
    let quotaClient: CodexQuotaClient

    init(quotaClient: CodexQuotaClient = CodexQuotaClient()) {
        self.quotaClient = quotaClient
    }

    func fetchSnapshot(now: Date) async throws -> UsageSnapshot {
        let quota = await quotaClient.fetchLimits()
        var snapshot = UsageSnapshot()
        snapshot.sessionLimit = quota.session
        snapshot.weekLimit = quota.week
        snapshot.codexResetCredits = quota.resetCredits
        snapshot.codexAccountEmail = quota.email
        snapshot.lastUpdated = now
        return snapshot
    }
}

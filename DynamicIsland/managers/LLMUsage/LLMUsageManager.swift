import Foundation
import SwiftUI
import Defaults

@MainActor
final class LLMUsageManager: ObservableObject {
    static let shared = LLMUsageManager()

    @Published var results: [ProviderID: UsageResult] = [:]
    @Published var isRefreshing = false
    @Published private(set) var codexAccounts: [CodexQuotaAccount] = []
    @Published private(set) var selectedCodexAccount: CodexQuotaAccount?
    @Published private(set) var isAuthorizingCodex = false
    @Published private(set) var codexAccountError: String?
    @Published private(set) var defaultCodexAccountEmail: String?

    private let injectedProviders: [UsageProvider]? // overrides the flag-based default when non-nil
    private var codexSelectionVersion = 0
    private var refreshAfterCodexSelection = false
    private static let codexAccountsKey = "AtollCodexQuotaAccounts"
    private static let selectedCodexAccountKey = "AtollSelectedCodexQuotaAccount"
    private var lastRefresh: Date = .distantPast
    private static let minRefreshInterval: TimeInterval = 60

    init(providers: [UsageProvider]? = nil) {
        self.injectedProviders = providers
        if providers == nil {
            let preferences = UserDefaults.standard
            if let data = preferences.data(forKey: Self.codexAccountsKey),
               let accounts = try? JSONDecoder().decode([CodexQuotaAccount].self, from: data) {
                codexAccounts = accounts
                let selectedID = preferences.string(forKey: Self.selectedCodexAccountKey)
                selectedCodexAccount = accounts.first { $0.id.uuidString == selectedID }
            }
        }
    }

    func selectCodexAccount(_ account: CodexQuotaAccount?) {
        guard selectedCodexAccount != account else { return }
        selectedCodexAccount = account
        UserDefaults.standard.set(account?.id.uuidString, forKey: Self.selectedCodexAccountKey)
        codexSelectionVersion += 1
        results[.codex] = .loading
        if isRefreshing {
            refreshAfterCodexSelection = true
        } else {
            refreshAll(force: true)
        }
    }

    func authorizeCodexAccount() {
        guard !isAuthorizingCodex else { return }
        isAuthorizingCodex = true
        codexAccountError = nil
        Task {
            defer { isAuthorizingCodex = false }
            do {
                let account = try await CodexQuotaAccounts.authorize()
                let updated = codexAccounts + [account]
                try persistCodexAccounts(updated)
                selectCodexAccount(account)
            } catch {
                codexAccountError = error.localizedDescription
            }
        }
    }

    func removeCodexAccount(_ account: CodexQuotaAccount) {
        guard !isRefreshing else { return }
        codexAccountError = nil
        do {
            if FileManager.default.fileExists(atPath: account.directory.path) {
                try FileManager.default.removeItem(at: account.directory)
            }
            try persistCodexAccounts(codexAccounts.filter { $0.id != account.id })
            if selectedCodexAccount == account { selectCodexAccount(nil) }
        } catch {
            codexAccountError = error.localizedDescription
        }
    }

    private func persistCodexAccounts(_ accounts: [CodexQuotaAccount]) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(accounts), forKey: Self.codexAccountsKey)
        codexAccounts = accounts
    }

    private static let allProviders: [UsageProvider] = [ClaudeUsageProvider(), CodexUsageProvider(), CursorUsageProvider(), AntigravityUsageProvider(), NewAPIUsageProvider()]

    private var enabledProviders: [UsageProvider] {
        if let injectedProviders { return injectedProviders }
        return Self.allProviders.filter { Defaults[$0.id.enabledKey] }
    }

    func refreshAll(force: Bool = false) {
        guard !isRefreshing else { return }
        guard force || Date().timeIntervalSince(lastRefresh) >= Self.minRefreshInterval else { return }
        lastRefresh = Date()
        isRefreshing = true
        let providers = enabledProviders
        let enabledIDs = Set(providers.map { $0.id })
        results = results.filter { enabledIDs.contains($0.key) } // drop disabled providers' stale results
        for p in providers where results[p.id] == nil { results[p.id] = .loading }
        let account = selectedCodexAccount
        let version = codexSelectionVersion
        Task { await runRefresh(providers: providers, codexAccount: account, codexVersion: version) }
    }

    private func runRefresh(providers: [UsageProvider], codexAccount: CodexQuotaAccount?, codexVersion: Int) async {
        let now = Date()
        await withTaskGroup(of: (ProviderID, UsageResult).self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        if provider.id == .codex, let codexAccount {
                            return (.codex, .success(try await CodexQuotaAccounts.snapshot(for: codexAccount, now: now)))
                        }
                        return (provider.id, .success(try await provider.fetchSnapshot(now: now)))
                    }
                    catch { return (provider.id, .failure(error.localizedDescription)) }
                }
            }
            for await (id, result) in group {
                if id == .codex && codexVersion != codexSelectionVersion { continue }
                if id == .codex, codexAccount == nil, case .success(let snapshot) = result {
                    defaultCodexAccountEmail = snapshot.codexAccountEmail
                }
                results[id] = result
            }
        }
        isRefreshing = false
        if refreshAfterCodexSelection {
            refreshAfterCodexSelection = false
            refreshAll(force: true)
        }
    }
}

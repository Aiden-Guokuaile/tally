// 移植自 Atoll（https://github.com/Ebullioscopic/Atoll），Copyright (C) 2024-2026 Atoll Contributors，GPL-3.0，见仓库 LICENSE 与 NOTICE。
// Tally 改动：日志走 UsageScanCache 增量扫描（~/.codex/sessions 有 1.4 GB，每轮全量重扫太贵）。
import Foundation

struct CodexUsageProvider: UsageProvider {
    let id: ProviderID = .codex
    let root: URL
    let quotaClient: CodexQuotaClient
    /// 引用类型：provider 是 struct，被 UsageStore 存着复制来复制去，缓存挂在盒子里才留得住。
    let scan: UsageScanCache

    init(root: URL = CodexHome.url.appendingPathComponent("sessions"),
         quotaClient: CodexQuotaClient = CodexQuotaClient(),
         scan: UsageScanCache = UsageScanCache(name: "codex")) {
        self.root = root
        self.quotaClient = quotaClient
        self.scan = scan
    }

    func fetchSnapshot(now: Date) async throws -> UsageSnapshot {
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw UsageError.notFound("No ~/.codex/sessions — Codex not detected")
        }
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw UsageError.notFound("No Codex usage logs found")
        }
        let files = en.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
        guard !files.isEmpty else { throw UsageError.notFound("No Codex usage logs found") }
        var snapshot = scan.aggregate(files: files, now: now)
        let quota = await quotaClient.fetchLimits()
        snapshot.sessionLimit = quota.session
        snapshot.weekLimit = quota.week
        snapshot.limitsNote = quota.note
        return snapshot
    }
}

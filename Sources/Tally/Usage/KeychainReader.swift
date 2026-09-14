// 移植自 Atoll（https://github.com/Ebullioscopic/Atoll），Copyright (C) 2024-2026 Atoll Contributors，GPL-3.0，见仓库 LICENSE 与 NOTICE。
// Tally 改动：删掉 Atoll 的 updateGenericPassword（永不写钥匙串）；`genericPassword` 与 `freshestGenericPassword` 的取值都改走 /usr/bin/security，不用 SecItemCopyMatching。
import Foundation
import Security

enum KeychainReader {
    /// 取值也走 `security`（3 秒砍掉），不用 `SecItemCopyMatching` 取数据：那条路要是弹授权框，调用会一直阻塞到有人点，
    /// 整轮用量刷新等着它、四家一起停（Cursor 的 `cursor-access-token`、Codex 的「Codex Auth」都走这里）。
    static func genericPassword(service: String, account: String? = nil) -> String? {
        secretViaSecurityCLI(service: service, account: account)
    }

    // Read the secret of the most-recently-modified generic password whose service starts
    // with `servicePrefix`. Claude Code namespaces its credential item by a per-install hash
    // ("Claude Code-credentials-<hash>") and rotates it, leaving the un-suffixed item stale;
    // following the freshest item keeps quota working across that migration without hardcoding
    // a hash. The enumeration requests attributes only (no kSecReturnData), so nothing is
    // decrypted here; the chosen item's secret is read by `secretViaSecurityCLI`.
    static func freshestGenericPassword(servicePrefix: String) -> (service: String, account: String?, secret: String)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return nil }

        let freshest = items
            .compactMap { attrs -> (service: String, account: String?, modified: Date)? in
                guard let service = attrs[kSecAttrService as String] as? String,
                      service.hasPrefix(servicePrefix),
                      let modified = attrs[kSecAttrModificationDate as String] as? Date
                else { return nil }
                return (service, attrs[kSecAttrAccount as String] as? String, modified)
            }
            .max { $0.modified < $1.modified }

        guard let freshest, let secret = secretViaSecurityCLI(service: freshest.service, account: freshest.account) else { return nil }
        return (freshest.service, freshest.account, secret)
    }

    /// 取值借 Apple 自己的 `security`，不用 `SecItemCopyMatching`：后者要 Tally 的 cdhash 在那条项的
    /// `partition_id` 里，而 Claude Code 每次刷新 token 都用 `add-generic-password -U` 整条重写那项，
    /// 分区列表回到写入方默认的 `apple-tool:`，授权一起被抹掉——每刷新一轮就弹一次「Tally 想要访问钥匙串」。
    /// `security` 是 Apple 工具，吃的正是那条 `apple-tool:` 授权，所以不弹。
    static func secretViaSecurityCLI(service: String, account: String?) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = securityArguments(service: service, account: account)
        let output = Pipe()
        task.standardOutput = output
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        // 万一某台机器上这条项没有 apple-tool 授权，security 会弹框然后一直等；砍掉它，
        // 宁可这轮没配额也不能挂住刷新。（已退出的进程再打信号是安全的。）
        let watchdog = DispatchWorkItem { task.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog.cancel()
        // 被砍掉和「没有这一项」（退出码 44）对调用方都是 nil，界面上一样是「没配置」；至少日志里分得开。
        // 被砍多半是那条项不认 security、弹了授权框：每轮刷新都会闪一下框。真有人报这个，给这条路加退避（像 Claude 的 TokenBox）
        if task.terminationReason == .uncaughtSignal {
            Log.error("security 3 秒没返回，多半在等钥匙串授权框，这一轮当没有：\(service)")
        }
        guard task.terminationStatus == 0 else { return nil }
        return parseSecurityOutput(data)
    }

    /// `-s` 是精确匹配，服务名要传枚举到的完整那个（前缀名字读不到）。
    static func securityArguments(service: String, account: String?) -> [String] {
        var arguments = ["find-generic-password", "-s", service]
        if let account { arguments += ["-a", account] }
        return arguments + ["-w"]
    }

    /// `-w` 打出来的密码尾巴带换行。
    static func parseSecurityOutput(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // Tally 改动：删掉了 Atoll 原有的 updateGenericPassword。这个 app 永远不写钥匙串。
}

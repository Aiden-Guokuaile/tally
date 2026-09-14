import Foundation
import Observation

/// 国内几家与 New API 中转站的凭据里，用户在设置里手填的那些。手填的优先；没填就去本机找（`CredentialDiscovery` 与各家自己的查找）。
/// 解码一律 `decodeIfPresent` 取默认值，以后加字段老文件也能读。
struct ProviderCredentials: Codable, Equatable {
    var deepseekKey = ""
    /// Kimi 开放平台的 key（查余额）。两个区的账号不通：cn = api.moonshot.cn（人民币），intl = api.moonshot.ai（美元）。
    var moonshotKey = ""
    var moonshotRegion = "cn"
    /// Kimi Code 会员的 key（`sk-kimi-…`，查 5 小时 / 周配额）。
    var kimiCodeKey = ""
    /// 智谱 GLM Coding Plan 的 key。两个区的 key 不通：cn = open.bigmodel.cn，intl = api.z.ai。
    var glmKey = ""
    var glmRegion = "cn"
    /// New API 站点根地址、个人设置里生成的访问令牌、用户 ID。
    var newapiBaseURL = ""
    var newapiToken = ""
    var newapiUserId = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProviderCredentials()
        deepseekKey = try c.decodeIfPresent(String.self, forKey: .deepseekKey) ?? d.deepseekKey
        moonshotKey = try c.decodeIfPresent(String.self, forKey: .moonshotKey) ?? d.moonshotKey
        moonshotRegion = try c.decodeIfPresent(String.self, forKey: .moonshotRegion) ?? d.moonshotRegion
        kimiCodeKey = try c.decodeIfPresent(String.self, forKey: .kimiCodeKey) ?? d.kimiCodeKey
        glmKey = try c.decodeIfPresent(String.self, forKey: .glmKey) ?? d.glmKey
        glmRegion = try c.decodeIfPresent(String.self, forKey: .glmRegion) ?? d.glmRegion
        newapiBaseURL = try c.decodeIfPresent(String.self, forKey: .newapiBaseURL) ?? d.newapiBaseURL
        newapiToken = try c.decodeIfPresent(String.self, forKey: .newapiToken) ?? d.newapiToken
        newapiUserId = try c.decodeIfPresent(String.self, forKey: .newapiUserId) ?? d.newapiUserId
    }
}

/// 手填凭据的唯一持有者：存 `providers.json`，权限 600。不进钥匙串：`KeychainReader` 只读，不加写函数。
@MainActor
@Observable
final class ProviderCredentialsStore {

    static let shared = ProviderCredentialsStore()

    var credentials: ProviderCredentials {
        didSet { if credentials != oldValue { save() } }
    }

    /// 最近一次落盘失败的原因，设置页红字显示。
    private(set) var saveError: String?

    let url: URL

    init(url: URL = PreferencesStore.directory.appendingPathComponent("providers.json")) {
        self.url = url
        credentials = ProviderCredentials()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            credentials = try JSONDecoder().decode(ProviderCredentials.self, from: Data(contentsOf: url))
        } catch {
            Log.error("凭据文件读取失败，按空的: \(url.path) \(error.localizedDescription)")
        }
    }

    /// 先在同目录建临时文件（创建时就是 600），再 rename 过去：原子，而且任何时刻文件都不是别人可读的。
    /// 先写再 chmod 的话，中间有一瞬间是 644。
    private func save() {
        let directory = url.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".providers-\(UUID().uuidString).json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(credentials)
            guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            guard rename(temp.path, url.path) == 0 else {
                let code = errno
                try? FileManager.default.removeItem(at: temp)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            saveError = nil
        } catch {
            saveError = "凭据没能写进 providers.json：\(error.localizedDescription)"
            Log.error("凭据写入失败: \(error.localizedDescription)")
        }
    }
}

/// 在本机找现成的 key：用户已经给 Claude Code 或别的工具配过，就不用在 Tally 里再填一遍。只读文件。
enum CredentialDiscovery {

    struct Found: Equatable {
        let token: String
        /// 从哪个地址找到的，决定区：api.moonshot.cn 还是 .ai、open.bigmodel.cn 还是 api.z.ai。
        let host: String
        /// 设置里显示给人看，如「Claude Code 设置」。
        let source: String
    }

    /// URL 的主机名（小写）；不带 scheme 的也认。
    static func host(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        return URLComponents(string: withScheme)?.host?.lowercased()
    }

    /// Claude Code 的 settings.json 里 `env.ANTHROPIC_BASE_URL` 指向 `hosts` 之一时，拿同一段 env 里的 token
    /// （`ANTHROPIC_AUTH_TOKEN`，没有再 `ANTHROPIC_API_KEY`）。主机名精确相等才认：用 contains 会把别人的地址也认进来，
    /// 还可能把用户真正的 Anthropic key 发给别家（codenotch #148）。
    static func claudeSettings(_ file: URL, hosts: Set<String>) -> Found? {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = object["env"] as? [String: Any],
              let base = env["ANTHROPIC_BASE_URL"] as? String,
              let host = host(of: base), hosts.contains(host)
        else { return nil }
        let token = [env["ANTHROPIC_AUTH_TOKEN"], env["ANTHROPIC_API_KEY"]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return token.map { Found(token: $0, host: host, source: "Claude Code 设置") }
    }

    /// 真 app 用的 Claude Code settings.json 位置（跟着 `CLAUDE_CONFIG_DIR`）。
    static var claudeSettingsFile: URL { ClaudeHome.url.appendingPathComponent("settings.json") }
}

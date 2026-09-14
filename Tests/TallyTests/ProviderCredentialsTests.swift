import XCTest
@testable import Tally

/// 国内几家与 New API 的凭据：手填的落盘权限、本机查找的主机名匹配（docs/ai.md「国内几家与 New API」）。
final class ProviderCredentialsTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tally-creds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    func testStoreWritesOwnerOnlyAndReadsBack() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("providers.json")
        let store = ProviderCredentialsStore(url: url)
        store.credentials.glmKey = "abc"
        store.credentials.glmRegion = "intl"
        XCTAssertNil(store.saveError)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600, "key 文件只给自己读")
        XCTAssertEqual(ProviderCredentialsStore(url: url).credentials.glmRegion, "intl")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".providers-") }
        XCTAssertTrue(leftovers.isEmpty, "临时文件 rename 过去，不留残")
    }

    func testOldFileWithoutNewKeysDecodes() throws {
        let decoded = try JSONDecoder().decode(ProviderCredentials.self, from: Data(#"{"deepseekKey":"sk-1"}"#.utf8))
        XCTAssertEqual(decoded.deepseekKey, "sk-1")
        XCTAssertEqual(decoded.glmRegion, "cn")
        XCTAssertEqual(decoded.newapiBaseURL, "")
    }

    func testHostParsing() {
        XCTAssertEqual(CredentialDiscovery.host(of: "https://open.bigmodel.cn/api/anthropic"), "open.bigmodel.cn")
        XCTAssertEqual(CredentialDiscovery.host(of: "API.Kimi.com/coding/"), "api.kimi.com", "不带 scheme、大小写都认")
        XCTAssertNil(CredentialDiscovery.host(of: "  "))
    }

    func testClaudeSettingsTokenOnlyForExactHost() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json")
        func write(_ env: [String: String]) throws {
            try JSONSerialization.data(withJSONObject: ["env": env, "hooks": [:]]).write(to: file)
        }
        let hosts: Set<String> = ["api.deepseek.com"]

        try write(["ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic", "ANTHROPIC_AUTH_TOKEN": "sk-ds"])
        XCTAssertEqual(CredentialDiscovery.claudeSettings(file, hosts: hosts),
                       CredentialDiscovery.Found(token: "sk-ds", host: "api.deepseek.com", source: "Claude Code 设置"))

        try write(["ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic", "ANTHROPIC_API_KEY": "sk-fallback"])
        XCTAssertEqual(CredentialDiscovery.claudeSettings(file, hosts: hosts)?.token, "sk-fallback", "没有 AUTH_TOKEN 再认 API_KEY")

        try write(["ANTHROPIC_BASE_URL": "https://api.deepseek.com.evil.example/anthropic", "ANTHROPIC_AUTH_TOKEN": "sk-x"])
        XCTAssertNil(CredentialDiscovery.claudeSettings(file, hosts: hosts), "主机名精确相等才认，不然用户的 key 会发给别人")

        try write(["ANTHROPIC_AUTH_TOKEN": "sk-anthropic"])
        XCTAssertNil(CredentialDiscovery.claudeSettings(file, hosts: hosts), "没指向这家就是用户自己的 Anthropic key，不能拿")
        XCTAssertNil(CredentialDiscovery.claudeSettings(dir.appendingPathComponent("missing.json"), hosts: hosts))
    }
}

import XCTest
@testable import Tally

final class KeychainReaderTests: XCTestCase {

    /// `-s` 是精确匹配，服务名要原样传；账号给了才加 `-a`；取值一定带 `-w`。
    func testSecurityArgumentsKeepServiceExact() {
        XCTAssertEqual(
            KeychainReader.securityArguments(service: "Claude Code-credentials-abc123", account: "aiden"),
            ["find-generic-password", "-s", "Claude Code-credentials-abc123", "-a", "aiden", "-w"]
        )
        XCTAssertEqual(
            KeychainReader.securityArguments(service: "Claude Code-credentials", account: nil),
            ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        )
    }

    /// `-w` 打出来的密码尾巴带换行，不去掉的话 JSON 解析不出 token。
    func testParseSecurityOutputTrimsTrailingNewline() {
        let payload = #"{"claudeAiOauth":{"accessToken":"tok"}}"#
        XCTAssertEqual(KeychainReader.parseSecurityOutput(Data((payload + "\n").utf8)), payload)
        XCTAssertNil(KeychainReader.parseSecurityOutput(Data("\n".utf8)))
        XCTAssertNil(KeychainReader.parseSecurityOutput(Data()))
    }

    /// 真起一次 `security`：项不存在时退出码是 44，要返回 nil 而不是空串。
    /// 服务名随机，碰不到任何真实凭据，也不会弹框。
    func testSecretViaSecurityCLIReturnsNilWhenItemMissing() {
        XCTAssertNil(KeychainReader.secretViaSecurityCLI(
            service: "tally-tests-absent-\(UUID().uuidString)",
            account: nil
        ))
    }

    /// Cursor / Codex 的钥匙串兜底改走 `security` 之后，项不存在照样是 nil。
    /// （「弹框不再卡住整轮刷新」要一条会弹框的真实项才验得了，单测覆盖不到。）
    func testGenericPasswordReturnsNilWhenItemMissing() {
        XCTAssertNil(KeychainReader.genericPassword(service: "tally-tests-absent-\(UUID().uuidString)"))
    }
}

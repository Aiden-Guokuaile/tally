import XCTest
@testable import Tally

final class BundleLocationTests: XCTestCase {

    /// 从 DMG 或下载目录直接打开时，Gatekeeper 把 app 搬到一个重启就没的临时路径跑；
    /// 那个路径写进 hooks 配置，重启后两边 agent 都会去调一个不存在的文件。
    func testTranslocatedAndVolumePathsAreUnstable() {
        XCTAssertTrue(BundleLocation.isUnstable("/private/var/folders/q_/x/T/AppTranslocation/E478/d/Tally.app/Contents/MacOS/tally-hook"))
        XCTAssertTrue(BundleLocation.isUnstable("/Volumes/Tally/Tally.app/Contents/MacOS/tally-hook"))
        XCTAssertFalse(BundleLocation.isUnstable("/Applications/Tally.app/Contents/MacOS/tally-hook"))
        XCTAssertFalse(BundleLocation.isUnstable("/Users/me/Applications/Tally.app/Contents/MacOS/tally-hook"))
    }
}

final class HookInstallerTests: XCTestCase {

    private var dir: URL!
    private let binary = "/Applications/Tally.app/Contents/MacOS/tally-hook"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tally-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func installer(hashes: [CodexHookEntry] = []) -> HookInstaller {
        HookInstaller(
            claudeSettings: dir.appendingPathComponent("settings.json"),
            codexHooks: dir.appendingPathComponent("hooks.json"),
            codexConfig: dir.appendingPathComponent("config.toml"),
            hookBinary: binary,
            codexHashes: { hashes }
        )
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func json(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(name))) as? [String: Any])
    }

    private func commands(_ root: [String: Any], _ event: String) -> [String] {
        ((root["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? [])
            .compactMap { ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String }
    }

    func testMissingFileInstallsAllSixAndReportsInstalled() throws {
        let i = installer()
        XCTAssertEqual(i.status(.claude), .missing)
        try i.install(.claude)
        XCTAssertEqual(i.status(.claude), .installed)
        let root = try json("settings.json")
        for event in HookSide.claude.events {
            XCTAssertEqual(commands(root, event), ["\"\(binary)\""], event)
        }
    }

    func testEmptyFileTreatedAsEmptyObjectAndInvalidJSONThrows() throws {
        try write("settings.json", "")
        try installer().install(.claude)
        XCTAssertEqual(installer().status(.claude), .installed)

        try write("hooks.json", "{not json")
        XCTAssertThrowsError(try installer().install(.codex)) { error in
            XCTAssertEqual(error as? HookInstallError, .invalidJSON(dir.appendingPathComponent("hooks.json").path))
        }
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("hooks.json"), encoding: .utf8), "{not json")
    }

    func testOtherHooksAreKeptAndIndicesUnchanged() throws {
        // 旧 node 匹配组排在别的 hook 前面：原位替换后别的 hook 还在原来的序号上
        try write("settings.json", """
        {"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"node /old/claude-event.js"}]},
                          {"matcher":"*","hooks":[{"type":"command","command":"node verify-gate.js"}]}],
                  "PreToolUse":[{"hooks":[{"type":"command","command":"node guard.js"}]}]}}
        """)
        let i = installer()
        XCTAssertEqual(i.status(.claude), .pointsElsewhere("SessionStart、UserPromptSubmit、Notification、PostToolUse、SessionEnd 未注册；命令指向 node /old/claude-event.js"))
        try i.install(.claude)
        let root = try json("settings.json")
        XCTAssertEqual(commands(root, "Stop"), ["\"\(binary)\"", "node verify-gate.js"])
        XCTAssertEqual(commands(root, "PreToolUse"), ["node guard.js"])
        XCTAssertEqual(i.status(.claude), .installed)
    }

    func testInstallIsIdempotentAndDeduplicates() throws {
        let i = installer()
        try i.install(.claude)
        let once = try Data(contentsOf: dir.appendingPathComponent("settings.json"))
        try i.install(.claude)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("settings.json")), once)

        try write("settings.json", """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\\"/x/tally-hook\\""}]},{"hooks":[{"type":"command","command":"\\"/y/tally-hook\\""}]}]}}
        """)
        XCTAssertEqual(i.status(.claude), .pointsElsewhere("SessionStart、UserPromptSubmit、Notification、PostToolUse、SessionEnd 未注册；命令指向 \"/x/tally-hook\""))
        try i.install(.claude)
        XCTAssertEqual(commands(try json("settings.json"), "Stop"), ["\"\(binary)\""])
    }

    func testFourOfSixReportsMissingEvents() throws {
        var hooks: [String: Any] = [:]
        for event in ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"] {
            hooks[event] = [["hooks": [["type": "command", "command": "\"\(binary)\"", "timeout": 5]]]]
        }
        try HookInstaller.save(["hooks": hooks], to: dir.appendingPathComponent("settings.json"))
        XCTAssertEqual(installer().status(.claude), .pointsElsewhere("Notification、PostToolUse 未注册"))
    }

    func testCodexInstallWritesProviderFlagAndPatchesTrustInPlace() throws {
        try write("hooks.json", """
        {"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"\\"/opt/homebrew/bin/node\\" \\"/old/claude-event.js\\" --provider codex","timeout":5}]}]}}
        """)
        try write("config.toml", """
        model = "x"

        [hooks.state."/Users/a/.codex/hooks.json:stop:0:0"]
        trusted_hash = "sha256:old"

        [hooks.state."/Users/a/.codex/hooks.json:pre_tool_use:0:0"]
        trusted_hash = "sha256:other"
        """)
        let hashes = [
            CodexHookEntry(key: "/Users/a/.codex/hooks.json:stop:0:0", command: "\"\(binary)\" --provider codex", hash: "sha256:new"),
            CodexHookEntry(key: "/Users/a/.codex/hooks.json:session_start:0:0", command: "\"\(binary)\" --provider codex", hash: "sha256:added"),
            CodexHookEntry(key: "/Users/a/.codex/hooks.json:pre_tool_use:0:0", command: "node guard.js", hash: "sha256:ignored"),
        ]
        let i = installer(hashes: hashes)
        try i.install(.codex)
        XCTAssertEqual(commands(try json("hooks.json"), "Stop"), ["\"\(binary)\" --provider codex"])
        XCTAssertEqual(commands(try json("hooks.json"), "PermissionRequest"), ["\"\(binary)\" --provider codex"])
        let toml = try String(contentsOf: dir.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertEqual(toml.components(separatedBy: "[hooks.state.\"/Users/a/.codex/hooks.json:stop:0:0\"]").count, 2, "旧块只有一份")
        XCTAssertTrue(toml.contains("trusted_hash = \"sha256:new\""))
        XCTAssertFalse(toml.contains("sha256:old"))
        XCTAssertTrue(toml.contains("trusted_hash = \"sha256:other\""), "别的 hook 的哈希不动")
        XCTAssertTrue(toml.contains("[hooks.state.\"/Users/a/.codex/hooks.json:session_start:0:0\"]\ntrusted_hash = \"sha256:added\""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("hooks.json.tally-backup").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.toml.tally-backup").path))
    }

    func testUninstallRemovesOnlyTallyGroupsAndEmptyEvents() throws {
        try write("settings.json", """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\\"\(binary)\\""}]},
                          {"matcher":"*","hooks":[{"type":"command","command":"node verify-gate.js"}]}],
                  "SessionStart":[{"hooks":[{"type":"command","command":"\\"\(binary)\\""}]}],
                  "PreToolUse":[{"hooks":[{"type":"command","command":"node guard.js"}]}]},
         "model":"opus"}
        """)
        let i = installer()
        try i.uninstall(.claude)
        XCTAssertEqual(i.status(.claude), .missing)
        let root = try json("settings.json")
        XCTAssertEqual(commands(root, "Stop"), ["node verify-gate.js"], "别的 hook 留着")
        XCTAssertEqual(commands(root, "PreToolUse"), ["node guard.js"])
        XCTAssertNil((root["hooks"] as? [String: Any])?["SessionStart"], "只剩 Tally 的事件连键一起删")
        XCTAssertEqual(root["model"] as? String, "opus", "别的顶层键不动")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.json.tally-backup").path))
        try i.uninstall(.claude)
        XCTAssertEqual(i.status(.claude), .missing, "重复移除是空操作")

        try write("settings.json", "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"\\\"\(binary)\\\"\"}]}]},\"model\":\"opus\"}")
        try i.uninstall(.claude)
        XCTAssertNil(try json("settings.json")["hooks"], "只剩 Tally 的话 hooks 顶层键一起删")
    }

    func testCodexUninstallRetrustsRemainingHooks() throws {
        try write("hooks.json", """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\\"\(binary)\\" --provider codex"}]},
                          {"hooks":[{"type":"command","command":"node ~/.codex/hooks/diff-residue-gate.js"}]}]}}
        """)
        try write("config.toml", "[hooks.state.\"hooks.json:Stop:1\"]\ntrusted_hash = \"old\"\n")
        // 移除后 diff-residue-gate 从序号 1 挪到 0，app-server 会报新键新哈希；sketchy 用户从没信任过，不能顺手给它信任
        let i = installer(hashes: [
            CodexHookEntry(key: "hooks.json:Stop:0", command: "node ~/.codex/hooks/diff-residue-gate.js", hash: "fresh", trusted: true),
            CodexHookEntry(key: "hooks.json:Stop:1", command: "node sketchy.js", hash: "nope", trusted: false),
        ])
        try i.uninstall(.codex)
        XCTAssertEqual(i.status(.codex), .missing)
        XCTAssertEqual(commands(try json("hooks.json"), "Stop"), ["node ~/.codex/hooks/diff-residue-gate.js"])
        let toml = try String(contentsOf: dir.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertTrue(toml.contains("[hooks.state.\"hooks.json:Stop:0\"]\ntrusted_hash = \"fresh\""), toml)
        XCTAssertFalse(toml.contains("nope"), "没信任过的不写")
    }

    func testTrustFailureRollsBackTheJSONEdit() throws {
        let original = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"node keep.js\"}]}]}}"
        try write("hooks.json", original)
        let failing = HookInstaller(
            claudeSettings: dir.appendingPathComponent("settings.json"),
            codexHooks: dir.appendingPathComponent("hooks.json"),
            codexConfig: dir.appendingPathComponent("config.toml"),
            hookBinary: binary,
            codexHashes: { throw HookInstallError.codexNotFound }
        )
        XCTAssertThrowsError(try failing.install(.codex))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("hooks.json"), encoding: .utf8), original, "哈希写不进去就退回原样")
        XCTAssertEqual(failing.status(.codex), .missing)

        let working = installer(hashes: [CodexHookEntry(key: "hooks.json:Stop:1", command: "\"\(binary)\" --provider codex", hash: "h")])
        try working.install(.codex)
        XCTAssertThrowsError(try failing.uninstall(.codex))
        XCTAssertEqual(working.status(.codex), .installed, "移除的第一步就查不到 codex，文件一个字节不动")
    }

    func testBackupIsWrittenBeforeChange() throws {
        try write("settings.json", "{\"hooks\":{}}")
        try installer().install(.claude)
        let backup = try String(contentsOf: dir.appendingPathComponent("settings.json.tally-backup"), encoding: .utf8)
        XCTAssertEqual(backup, "{\"hooks\":{}}")
    }

    func testAppServerParse() throws {
        let output = """
        {"jsonrpc":"2.0","id":1,"result":{}}
        {"jsonrpc":"2.0","id":2,"result":{"data":[{"hooks":[{"key":"/h.json:stop:1:0","trustStatus":"untrusted","currentHash":"sha256:abc","config":{"type":"command","command":"\\"/A/tally-hook\\" --provider codex"}}]}]}}
        """
        let entries = try CodexAppServer.parse(output)
        XCTAssertEqual(entries, [CodexHookEntry(key: "/h.json:stop:1:0", command: "\"/A/tally-hook\" --provider codex", hash: "sha256:abc", trusted: false)])
        XCTAssertThrowsError(try CodexAppServer.parse("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}"))
    }

    /// id 为 2 但带 error 的响应：要把它的话说出来。原来只认 result，
    /// 于是「不支持这个方法」会被报成「响应里没有 id 为 2 的结果」，远端用户没法反馈到点子上。
    func testAppServerSurfacesJSONRPCError() {
        let output = #"{"id":2,"error":{"code":-32601,"message":"Method not found: hooks/list"}}"#
        XCTAssertThrowsError(try CodexAppServer.parse(output)) { error in
            XCTAssertEqual(error as? HookInstallError,
                           .appServerFailed("hooks/list 返回错误：Method not found: hooks/list"))
        }
    }

    /// 原来靠 `"id":2` 这个子串找结果行，响应里带空格（`"id": 2`）就整条漏掉，
    /// 报「响应里没有 id 为 2 的结果」——用户装 Codex hook 时就撞上了这个。
    func testAppServerParseAcceptsSpacedId() throws {
        let output = """
        {"jsonrpc": "2.0", "id": 1, "result": {}}
        {"jsonrpc": "2.0", "id": 2, "result": {"data": [{"hooks": [{"key": "/h.json:stop:1:0", "trustStatus": "trusted", "currentHash": "sha256:abc", "config": {"type": "command", "command": "\\"/A/tally-hook\\" --provider codex"}}]}]}}
        """
        XCTAssertEqual(try CodexAppServer.parse(output).map { $0.hash }, ["sha256:abc"])
    }

    /// 远端那台机器：登录 shell 里没有 codex（登录 shell 不读 `.zshrc`，zsh 只在交互时读它），
    /// 交互 shell 才报得出来，中间还夹着 instant prompt 那类噪声。顺带验 PATH 也一起带回来了——
    /// codex 是 `#!/usr/bin/env node` 的脚本，node 未必和它同目录，光有 codex 路径跑不起来。
    func testResolveFallsBackToInteractiveShellAndKeepsPath() throws {
        let dir = try makeTemporaryDirectory()
        let codex = try makeExecutable(dir.appendingPathComponent("codex"), body: "#!/bin/sh\n")
        let shell = try makeExecutable(dir.appendingPathComponent("shell.sh"), body: """
        #!/bin/sh
        case "$1" in
          -lc) exit 1 ;;
          -ilc) echo 'instant prompt 噪声'; echo '\(codex.path)'; echo 'TALLY_PATH=/usr/local/bin:/usr/bin' ;;
        esac
        """)
        let restore = useAsLoginShell(shell)
        defer { restore(); try? FileManager.default.removeItem(at: dir) }

        let located = try CodexAppServer.resolve()
        XCTAssertEqual(located.codex, codex.path)
        XCTAssertEqual(located.path, "/usr/local/bin:/usr/bin")
    }

    /// 有人把 codex 包成 shell 函数（远端那台就是，函数里换了 CODEX_HOME）：
    /// `command -v` 只回名字不回路径，不能把「codex」当成可执行文件路径拿去跑。PATH 还是要留下。
    func testProbeIgnoresShellFunctionButKeepsPath() throws {
        let dir = try makeTemporaryDirectory()
        let shell = try makeExecutable(dir.appendingPathComponent("shell.sh"), body: """
        #!/bin/sh
        echo 'codex'
        echo 'TALLY_PATH=/usr/local/bin:/usr/bin'
        """)
        let restore = useAsLoginShell(shell)
        defer { restore(); try? FileManager.default.removeItem(at: dir) }

        let found = CodexAppServer.probe("-lc")
        XCTAssertNil(found.codex)
        XCTAssertEqual(found.path, "/usr/local/bin:/usr/bin")
    }

    /// app 自己的 PATH 只有 launchd 给的几个系统目录，跑 codex 会 `env: node: No such file or directory`，
    /// 界面上却显示「没拿到信任哈希」。shell 的 PATH 打头，codex 那层目录也补上。
    func testAppServerEnvironmentPrependsShellPathAndCodexDirectory() {
        let environment = CodexAppServer.environment(codex: "/fake/bin/codex", path: "/usr/local/bin",
                                                     codexHome: URL(fileURLWithPath: "/fake/home"))
        XCTAssertEqual(environment["PATH"]?.hasPrefix("/fake/bin:/usr/local/bin:"), true)
        // 不给 CODEX_HOME 的话 app-server 读默认的 ~/.codex，算出来的哈希对不上我们刚写的那份 hooks.json
        XCTAssertEqual(environment["CODEX_HOME"], "/fake/home")
    }

    // MARK: 上面三个用的小工具

    private func makeTemporaryDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeExecutable(_ url: URL, body: String) throws -> URL {
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func useAsLoginShell(_ shell: URL) -> () -> Void {
        let saved = ProcessInfo.processInfo.environment["SHELL"]
        setenv("SHELL", shell.path, 1)
        return { if let saved { setenv("SHELL", saved, 1) } else { unsetenv("SHELL") } }
    }
}

/// codex 的家可以被 `CODEX_HOME` 指到别处（有人给终端 codex 单开一个家，跟 ChatGPT 桌面版隔开）。
/// hook 装错家 = 装了也收不到会话，所以这几条得钉住。
final class CodexHomeTests: XCTestCase {

    private func withoutEnvironmentValue(_ body: () -> Void) {
        let saved = ProcessInfo.processInfo.environment["CODEX_HOME"]
        unsetenv("CODEX_HOME")
        body()
        if let saved { setenv("CODEX_HOME", saved, 1) }
    }

    func testFallsBackToDefaultHome() {
        withoutEnvironmentValue {
            let expected = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            XCTAssertEqual(CodexHome.resolve(shellValue: nil), expected)
            XCTAssertEqual(CodexHome.resolve(shellValue: "   "), expected)
        }
    }

    /// app 的环境里没有用户 shell 的变量，所以 shell 问回来的那个值必须算数。
    func testUsesShellValueAndExpandsTilde() {
        withoutEnvironmentValue {
            XCTAssertEqual(CodexHome.resolve(shellValue: "/Users/x/.codex-cli").path, "/Users/x/.codex-cli")
            XCTAssertEqual(CodexHome.resolve(shellValue: "~/.codex-cli").path,
                           NSHomeDirectory() + "/.codex-cli")
        }
    }

    /// 从终端启动 Tally 时环境里就带着 CODEX_HOME，那份比问 shell 更贴当下。
    func testEnvironmentWinsOverShell() {
        let saved = ProcessInfo.processInfo.environment["CODEX_HOME"]
        setenv("CODEX_HOME", "/tmp/from-environment", 1)
        defer { if let saved { setenv("CODEX_HOME", saved, 1) } else { unsetenv("CODEX_HOME") } }
        XCTAssertEqual(CodexHome.resolve(shellValue: "/tmp/from-shell").path, "/tmp/from-environment")
    }

    /// 标记行的解析：shell 启动脚本自己也会往 stdout 写东西，认前缀而不是整段拿。
    func testValuePicksMarkedLineAndTreatsEmptyAsMissing() {
        XCTAssertEqual(LoginShell.value(["主题噪声", "TALLY_CODEX_HOME=/a/b"], marker: "TALLY_CODEX_HOME"), "/a/b")
        XCTAssertNil(LoginShell.value(["TALLY_CODEX_HOME="], marker: "TALLY_CODEX_HOME"))
        XCTAssertNil(LoginShell.value(["别的东西"], marker: "TALLY_CODEX_HOME"))
    }
}

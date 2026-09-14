import Foundation
import TallyKit

// tally-hook [--provider claude|codex]
//
// Claude Code / Codex 的 hook 入口：读 stdin 的事件 JSON，写会话状态文件。
// 三条硬约束：永远 exit 0（Stop 上 exit 2 会阻止 agent 结束回合）、900 ms 自退、校验不过不写。

DispatchQueue.global().asyncAfter(deadline: .now() + 0.9) { exit(0) }

var provider = "claude"
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    if argument == "--provider", let value = arguments.next() { provider = value }
}

let raw = FileHandle.standardInput.readDataToEndOfFile()
if let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
    let environment = ProcessInfo.processInfo.environment
    let directory = environment["TALLY_SESSIONS_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        ?? HookRunner.defaultDirectory
    let options = HookOptions(provider: provider, directory: directory, environment: environment)
    _ = HookRunner.run(input: object, options: options, table: SysctlProcessTable())
}
exit(0)

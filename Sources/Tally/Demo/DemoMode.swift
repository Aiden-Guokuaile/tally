import Foundation

/// `--demo`：每一页都换成编出来的数据，给 README 截图、录 GIF 用——真会话、项目目录、花费、IP、在跑的 app、文件一样都不露。
/// 各 store 在 `shared` 或 `start()` 里认它；读写真数据的路一律不走，挡掉哪些见 docs/panel.md「演示模式」。
enum DemoMode {
    /// 和其他启动参数同一套解析，只算一次；测试进程拿到的是 xctest 的参数，恒为假。
    static let isOn = LaunchOptions.parse(CommandLine.arguments).demo
}

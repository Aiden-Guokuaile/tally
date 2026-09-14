import AppKit
import SwiftUI

/// 帮助：顶上是「关于」，下面只留 hook 的装与卸——面板怎么用、数据从哪来在界面上一看就知道，写在这里没人读。
struct HelpPage: View {

    /// Unicode Braille cells keep the approved SD Gundam silhouette aligned.
    private static let gundam = """
    ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡀
    ⠀⢀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⣀⣀⣀⣀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⢤⡢⠋
    ⠀⠀⠙⢔⠄⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣠⠖⠉⠀⠀⠀⣴⣾⣿⣷⣦⡀⠀⠀⠀⠀⠀⠀⠀⠀⢀⠠⠐⣈⡴⠋
    ⠀⠀⠀⠀⠳⣌⠐⠄⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⡇⣰⣶⣶⣶⡆⢸⣿⣿⣿⣿⣿⡄⠀⠀⠀⢀⡠⠔⠊⢀⣠⠞⠁
    ⠀⠀⠀⠀⠀⠈⢳⣄⠈⠑⠤⡀⠀⠀⠀⠀⠀⠀⣸⠀⣿⣿⣿⣿⣧⠈⣿⣿⣿⣟⡻⠿⡄⠄⠂⠁⠀⢀⣴⠟⠁
    ⠀⠀⠀⠀⠀⠀⠀⠙⢷⣄⠀⠀⠑⠢⣀⡠⠖⠋⡏⢰⡿⠿⠿⠿⢿⠀⢻⣿⣿⠥⠒⠉⠀⠀⠀⣠⣾⠟⠁
    ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠻⣧⡀⠀⠀⠀⠙⠢⢴⣷⠋⠉⠉⠉⢹⣦⡡⠞⠋⠀⠀⠀⠀⢀⣴⣾⣿⣷⡄
    ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⢻⣦⡀⠀⠀⠀⢠⠇⠀⠀⠀⠀⢸⡿⠀⠀⠀⠀⠀⣀⣴⣿⣿⣿⣿⣿⣿⣆
    ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣿⣎⠻⣦⡀⠀⡞⠀⠀⠀⠀⠀⢸⣇⠀⠀⠀⣠⣾⣿⣿⣿⢳⣿⡞⣿⣿⣿⡆
    ⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⣼⠘⠃⡠⠘⠻⣆⡇⠀⠀⠀⠀⢠⣿⣿⣀⣴⠾⠋⠉⠙⠻⢿⣯⣿⣵⣿⣿⣿⡿⠲⢄⡀
    ⠀⠀⠀⠀⠀⠀⠀⢠⠎⠀⡇⠠⠀⠀⠀⠀⠈⠣⣀⠀⠀⢠⣿⣿⠿⠋⠀⠀⠀⠀⠀⠀⠀⠙⠻⣿⠿⠛⠁⠀⢀⣴⣷
    ⠀⠀⠀⠀⠀⠀⠀⡞⢰⣾⡇⢰⣦⣄⣀⠀⠀⠀⠈⠓⢤⠿⠋⠁⠀⠀⠀⠀⢀⣀⣠⣤⣴⣶⣾⠀⠀⣿⣿⣿⢹⣿⣿⡆
    ⠀⠀⠀⠀⠀⠀⠀⡇⡟⠿⡇⢸⡟⣿⡇⠉⠙⠒⢶⣤⣤⣤⣤⣶⣶⡶⠛⠋⠉⠁⠀⢸⣿⣿⢹⠀⠀⠿⠿⢻⠀⣿⣿⡇
    ⠀⠀⠀⠀⠀⠀⠀⡇⣿⣿⣇⠘⡇⣿⣧⠀⠀⠀⠀⣿⣿⣿⣿⣿⣿⡇⠀⠀⠀⠀⠀⣼⣿⣿⠸⠀⢠⣿⣿⣿⠀⣿⣿⡇
    ⠀⠀⠀⠀⠀⠀⠀⡇⢨⣍⣻⠀⠹⣜⡿⣷⣤⣤⣾⠿⠟⠛⠻⠿⣿⣿⣦⣤⣤⣴⣾⣿⡿⠟⠁⠀⠸⠛⣛⡋⢸⣿⣿⠇
    ⠀⠀⠀⠀⠀⠀⠀⢸⠘⣿⣿⡀⠀⠈⢻⡎⠙⠉⠀⠀⠒⠓⠢⠄⠀⠈⠉⠛⠋⢩⡞⠉⠀⠀⣤⣶⣿⣿⣿⠇⣸⣿⡟
    ⠀⠀⢀⣀⣀⣀⡀⠀⠑⠢⣉⡇⠀⠀⢸⣧⠀⠀⠀⠀⠉⠉⠑⠂⠀⠀⠀⠀⠀⢸⡇⠀⠀⠀⡿⠟⠛⢋⣡⣴⠟⠋⠀⠀⠀⢀⣀⣀⣀
    ⠀⣰⠉⠀⠉⠙⠻⢿⣶⣦⣤⣙⢄⠀⠘⣿⡀⠀⠀⠀⣾⣿⣷⡄⠀⠀⠀⠀⠀⣿⡇⠀⠀⠀⣠⣴⠿⣿⣿⣦⡤⠴⠒⠚⠉⠉⠀⣰⣿⣿⡆
    ⠀⣿⠀⠀⠀⠀⠀⠀⠈⢹⣿⣿⣿⣿⡂⢟⣉⣷⣤⣰⢹⣿⢹⣿⡄⣀⣠⣴⣿⣿⣧⣴⣶⣿⣿⣶⣶⡟⠉⠀⠀⠀⠀⠀⠀⠀⢸⣿⣿⣿⣷
    ⢰⣿⠀⠀⠀⠀⠀⠀⠀⢨⣿⣿⣿⠿⠿⢿⣿⢻⣿⣿⣾⣿⣾⣿⣿⣿⣿⣿⣿⣷⢸⡿⢿⣿⣿⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀⠀⣼⣿⣿⣿⣿
    ⠈⣿⣄⠀⠀⠀⠀⠀⠀⣼⡿⣵⣶⣶⣶⣶⣌⠻⡇⠀⠀⠀⠀⠀⠀⢀⡾⠟⣫⣵⣷⣶⣶⣶⣶⢶⣿⠀⠀⠀⠀⠀⠀⠀⠀⣠⣿⣿⣿⣿⡿
    ⠀⠈⢿⣧⡀⠀⠀⠀⢠⡿⣹⣿⣿⣿⣿⣿⣿⣆⣁⣀⣀⣀⣒⣒⣐⣩⣴⣿⣿⣿⣿⣿⣿⡿⢣⣿⣿⡆⠀⠀⠀⠀⠀⣰⣿⣿⣿⣿⣿⡟⠁
    ⠀⠀⠀⢙⣷⡀⠀⠀⢸⠁⣉⣙⣛⠛⠛⠻⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⠿⠛⠛⠛⠛⠛⡛⠁⣾⣿⣿⣧⠀⠀⠀⠀⣰⣿⣿⣿⣿⠛⠋
    ⠀⠀⠀⣸⣿⣿⣷⣦⣿⡇⢯⣭⣉⣉⣙⣃⡼⣟⣛⣛⣛⣛⣻⣿⣿⡆⣟⣛⣛⣉⣉⣉⣉⠀⣿⣿⣿⣿⣷⣤⣴⣾⣿⣿⣿⡽⣿⡀
    ⠀⠀⠀⠻⣿⣿⣿⣿⣿⣹⡘⠶⠶⠶⠤⣭⢠⢻⣿⣿⣿⣿⣿⢹⣿⡇⢩⣭⣭⡤⠤⠶⠶⠀⣿⣿⣿⣿⡿⠁⠸⣿⣿⣿⣿⣷⠻⠇
    ⠀⠀⠀⠀⠀⠙⠻⢿⡿⠁⠙⠻⣷⣶⣶⣶⣾⡜⣿⣿⣿⣿⣿⡾⣿⣿⣶⣶⣶⣶⣶⣶⣶⣾⣿⣿⡿⠟⠁⠀⠀⢻⣿⠿⠛⠁
    ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢻⣿⣿⣿⣿⣷⢻⣿⣿⣿⣿⣧⣿⣿⣿⣿⣿⣿⣿⡿⣰⣿⣿⡟⠀⠀⠀⠀⠀⠈
    ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⠉⠛⠛⠛⠛⠛⠛⠿⠿⠿⠿⠛⠛⠛⠛⠛⠛⠃⠛⠛⠉
    """

    private struct Section: Identifiable {
        let id: String
        let body: String
    }

    private static let sections: [Section] = [
        Section(id: "装 hook", body: "会话列表要靠 hook。在设置的 hook 一页点两个「安装」，改 ~/.claude/settings.json 与 ~/.codex/hooks.json，改前留 .tally-backup 备份；已经开着的 Codex 会话要重开一次才生效。"),
        Section(id: "卸载", body: "先在设置里点两个「移除」退掉 hook 注册，再把 Tally.app 拖进废纸篓。macOS 不让 app 在被删除时自己清理，所以分两步。"),
    ]

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                about
                Divider()
                ForEach(Self.sections) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.id)
                            .font(.headline)
                        Text(section.body)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 关于块：图标、名字、版本、个人开发者声明。
    private var about: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
            Text("Tally")
                .font(.system(size: 24, weight: .semibold))
            Text("版本 \(Self.version)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(verbatim: Self.gundam)
                .font(.custom("Menlo", fixedSize: 9))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize()
                .accessibilityLabel("Q 版高达半身字符画")
                .padding(.vertical, 8)
            Text("高达护航 · 用量有数")
                .font(.system(size: 12, weight: .medium))
            Text("本应用由「Aiden-Guokuaile」个人开发并所有")
                .font(.system(size: 13, weight: .medium))
                .padding(.top, 4)
            Text("个人开发者作品，非商业组织出品，不收集任何用户数据。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }
}

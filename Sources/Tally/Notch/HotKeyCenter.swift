import AppKit
import Carbon.HIToolbox

/// ⌥⇧T 全局快捷键：Carbon `RegisterEventHotKey` 不要辅助功能授权，`CGEvent` 监听要。只有一个动作，回调里不用反查 id。
///
/// 用 ⌥⇧ 而不是 ⌃⌥：⌃⌥ 打头的组合被代理类工具占得多（作者的 Watchdog 就把 ⌃⌥T 给了「开关 TUN」）。
@MainActor
final class HotKeyCenter {

    static let shared = HotKeyCenter()
    static let label = "⌥⇧T"

    private var handler: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private(set) var isActive = false

    private init() {}

    func setHandler(_ body: @escaping () -> Void) {
        handler = body
    }

    func setEnabled(_ enabled: Bool) {
        enabled ? register() : unregister()
    }

    private func register() {
        guard !isActive else { return }
        installEventHandler()
        // signature 是固定四字符码 TALY
        let hotKeyID = EventHotKeyID(signature: OSType(0x54414C59), id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(optionKey | shiftKey), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKey = ref
            isActive = true
            Log.debug("⌥⇧T 已注册")
        } else {
            Log.error("⌥⇧T 注册失败: \(status)")
        }
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        isActive = false
        Log.debug("⌥⇧T 已注销")
    }

    private func installEventHandler() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            // Carbon 回调在主线程上跑，但编译器不知道，显式声明一下
            MainActor.assumeIsolated { HotKeyCenter.shared.handler?() }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}

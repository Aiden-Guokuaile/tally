import CoreAudio
import CoreMediaIO
import Foundation
import Observation

/// 摄像头 / 麦克风有没有被别的进程占用。只读设备的 `DeviceIsRunningSomewhere` 属性，不开流，所以不要权限、不弹授权框。
/// 事件驱动：给每个输入设备挂属性监听，另外监听设备列表（热插拔后重新挂）。关掉就全部摘掉。
/// 比 Atoll 多做两件事：麦克风盯全部输入设备而不只是默认的，设备列表变化时重挂。蓝牙耳机偶尔会在没人录音时也报占用，接受。
@MainActor
@Observable
final class PrivacyWatcher {

    static let shared = PrivacyWatcher()

    private(set) var cameraInUse = false
    private(set) var microphoneInUse = false

    private var enabled = false
    private var audioDevices: [AudioObjectID] = []
    private var cameraDevices: [CMIOObjectID] = []
    private var audioBlock: AudioObjectPropertyListenerBlock?
    private var cameraBlock: CMIOObjectPropertyListenerBlock?
    private var audioListBlock: AudioObjectPropertyListenerBlock?
    private var cameraListBlock: CMIOObjectPropertyListenerBlock?

    private static var audioRunning = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static var audioList = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static var cameraRunning = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )
    private static var cameraList = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            let audioBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.evaluate() }
            let cameraBlock: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.evaluate() }
            let audioListBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.attachAudio() }
            let cameraListBlock: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.attachCamera() }
            self.audioBlock = audioBlock
            self.cameraBlock = cameraBlock
            self.audioListBlock = audioListBlock
            self.cameraListBlock = cameraListBlock
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.audioList, .main, audioListBlock)
            CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &Self.cameraList, .main, cameraListBlock)
            attachAudio()
            attachCamera()
        } else {
            detachAudio()
            detachCamera()
            if let audioListBlock {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.audioList, .main, audioListBlock)
            }
            if let cameraListBlock {
                CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &Self.cameraList, .main, cameraListBlock)
            }
            audioBlock = nil
            cameraBlock = nil
            audioListBlock = nil
            cameraListBlock = nil
            cameraInUse = false
            microphoneInUse = false
        }
    }

    /// 测试用：当前挂着监听的设备数。
    var deviceCounts: (microphones: Int, cameras: Int) { (audioDevices.count, cameraDevices.count) }

    // MARK: 麦克风

    private func attachAudio() {
        detachAudio()
        guard let block = audioBlock else { return }
        audioDevices = Self.audioInputDevices()
        for device in audioDevices {
            AudioObjectAddPropertyListenerBlock(device, &Self.audioRunning, .main, block)
        }
        evaluate()
    }

    private func detachAudio() {
        if let block = audioBlock {
            for device in audioDevices {
                AudioObjectRemovePropertyListenerBlock(device, &Self.audioRunning, .main, block)
            }
        }
        audioDevices = []
    }

    static func audioInputDevices() -> [AudioObjectID] {
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &audioList, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &audioList, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.filter { device in
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return false }
            // 不是每个设备都有这个属性，没有的挂不上监听，直接跳过
            return AudioObjectHasProperty(device, &audioRunning)
        }
    }

    private static func audioRunning(_ device: AudioObjectID) -> Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &audioRunning, 0, nil, &size, &value) == noErr && value != 0
    }

    // MARK: 摄像头

    private func attachCamera() {
        detachCamera()
        guard let block = cameraBlock else { return }
        cameraDevices = Self.cameraDevicesList()
        for device in cameraDevices {
            CMIOObjectAddPropertyListenerBlock(device, &Self.cameraRunning, .main, block)
        }
        evaluate()
    }

    private func detachCamera() {
        if let block = cameraBlock {
            for device in cameraDevices {
                CMIOObjectRemovePropertyListenerBlock(device, &Self.cameraRunning, .main, block)
            }
        }
        cameraDevices = []
    }

    static func cameraDevicesList() -> [CMIOObjectID] {
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &cameraList, 0, nil, &size) == 0 else { return [] }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &cameraList, 0, nil, size, &used, &devices) == 0 else { return [] }
        return devices.filter { device in
            var streams = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
                mScope: CMIOObjectPropertyScope(kCMIODevicePropertyScopeInput),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            var streamSize: UInt32 = 0
            return CMIOObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == 0 && streamSize > 0
        }
    }

    private static func cameraRunning(_ device: CMIOObjectID) -> Bool {
        var value: UInt32 = 0
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return CMIOObjectGetPropertyData(device, &cameraRunning, 0, nil, size, &used, &value) == 0 && value != 0
    }

    private func evaluate() {
        guard enabled else { return }
        microphoneInUse = audioDevices.contains { Self.audioRunning($0) }
        cameraInUse = cameraDevices.contains { Self.cameraRunning($0) }
    }
}

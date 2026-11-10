import Foundation
import CoreAudio
import ClawdCore

public final class SelectedDeviceListener: ReleaseDeviceSource {
    public private(set) var device: AudioDeviceID?
    public private(set) var uid: String?
    public private(set) var registrationStatus: OSStatus?
    public var onChange: ((String?, Bool?) -> Void)?
    private var block: AudioObjectPropertyListenerBlock?
    private var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    public init() {}
    deinit { stop() }
    public static func resolve(uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !devices.isEmpty, AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.first { deviceUID($0) == uid }
    }
    public static func deviceUID(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    public func running() -> Bool? {
        guard let device, Self.deviceUID(device) == uid else { return nil }
        var value: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }
    @discardableResult public func start(uid: String?) -> Bool? {
        stop()
        guard let uid, let device = Self.resolve(uid: uid) else { return nil }
        self.uid = uid; self.device = device
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }; self.onChange?(Self.deviceUID(device), self.running())
        }
        self.block = block
        registrationStatus = AudioObjectAddPropertyListenerBlock(device, &address, .main, block)
        guard registrationStatus == noErr else { stop(); return nil }
        return running()
    }
    public func stop() {
        if let device, let block { AudioObjectRemovePropertyListenerBlock(device, &address, .main, block) }
        block = nil; device = nil; uid = nil
    }
}

import CoreAudio

/// Silencia a saída de som do Mac enquanto espelha (o som vai pra TV) e devolve como estava depois.
enum MacAudio {
    private static var saved: (device: AudioDeviceID, muted: UInt32?, volume: Float32?)?

    static func silence() {
        guard saved == nil, let dev = defaultOutput() else { return }
        let muted: UInt32? = get(dev, kAudioDevicePropertyMute)
        let volume: Float32? = get(dev, kAudioDevicePropertyVolumeScalar)
        saved = (dev, muted, volume)
        // prefere "mudo"; se o aparelho não deixar (ex.: HDMI), zera o volume
        if !set(dev, kAudioDevicePropertyMute, UInt32(1)) { _ = set(dev, kAudioDevicePropertyVolumeScalar, Float32(0)) }
    }

    static func restore() {
        guard let s = saved else { return }
        saved = nil
        if let m = s.muted { _ = set(s.device, kAudioDevicePropertyMute, m) }
        if let v = s.volume { _ = set(s.device, kAudioDevicePropertyVolumeScalar, v) }
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var id = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr ? id : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private static func get<T>(_ dev: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> T? {
        var addr = address(selector)
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, value) == noErr ? value.pointee : nil
    }

    private static func set<T>(_ dev: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ value: T) -> Bool {
        var addr = address(selector)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(dev, &addr), AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue else { return false }
        var v = value
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v) == noErr
    }
}

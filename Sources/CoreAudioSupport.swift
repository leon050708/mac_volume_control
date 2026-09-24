import AppKit
import CoreAudio

struct AudioFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else { throw AudioFailure(message: "\(action)失败（Core Audio \(status)）") }
    }
    static func value<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         initial: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var a = address(selector, scope)
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutableBytes(of: &result) { bytes in
            try check(AudioObjectGetPropertyData(id, &a, 0, nil, &size, bytes.baseAddress!), "读取音频属性")
        }
        return result
    }
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var a = address(selector)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(id, &a, 0, nil, &size, &result), "读取名称")
        return result?.takeRetainedValue() as String? ?? ""
    }
    static func objects(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var a = address(selector, scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size), "读取列表长度")
        guard size > 0 else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try result.withUnsafeMutableBytes { bytes in
            try check(AudioObjectGetPropertyData(id, &a, 0, nil, &size, bytes.baseAddress!), "读取列表")
        }
        return Array(result.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
    static func defaultOutput() throws -> AudioObjectID {
        try value(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
    }
    static func formats(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [AudioStreamBasicDescription] {
        try objects(device, kAudioDevicePropertyStreams, scope: scope).map {
            try value($0, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
        }
    }
    static func validate(_ formats: [AudioStreamBasicDescription]) throws -> (channels: UInt32, rate: Double) {
        let channels = formats.reduce(UInt32(0)) { $0 + $1.mChannelsPerFrame }
        guard (1...2).contains(channels), let first = formats.first,
              formats.allSatisfy({
                  $0.mFormatID == kAudioFormatLinearPCM && $0.mBitsPerChannel == 32 &&
                  $0.mFormatFlags & kAudioFormatFlagIsFloat != 0 &&
                  $0.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 &&
                  $0.mBytesPerFrame == 4 * ($0.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 1 : $0.mChannelsPerFrame) &&
                  $0.mSampleRate == first.mSampleRate && $0.mSampleRate > 0
              }) else {
            throw AudioFailure(message: "第一版仅支持 Float32 单声道／立体声输出，请使用内置扬声器或普通立体声耳机。")
        }
        return (channels, first.mSampleRate)
    }
}

struct AudioProcess: Identifiable {
    let id: AudioObjectID
    let pid: pid_t
    let name: String
    let bundleID: String
    let running: Bool

    static func list() throws -> [AudioProcess] {
        try HAL.objects(HAL.system, kAudioHardwarePropertyProcessObjectList).compactMap { id in
            guard let pid = try? HAL.value(id, kAudioProcessPropertyPID, initial: pid_t(0)),
                  pid != ProcessInfo.processInfo.processIdentifier else { return nil }
            let bundle = (try? HAL.string(id, kAudioProcessPropertyBundleID)) ?? ""
            let app = NSRunningApplication(processIdentifier: pid)
            let name = app?.localizedName ?? (try? HAL.string(id, kAudioObjectPropertyName)) ?? bundle
            let running = (try? HAL.value(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) == 1
            return AudioProcess(id: id, pid: pid, name: name.isEmpty ? "进程 \(pid)" : name,
                                bundleID: bundle, running: running)
        }.sorted { a, b in
            if a.running != b.running { return a.running }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

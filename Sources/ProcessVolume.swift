import CoreAudio
import Foundation

// All lifecycle operations run on the main thread. Only the C renderer runs on the HAL thread.
final class ProcessVolume {
    let process: AudioProcess
    private(set) var output: AudioObjectID = 0
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private var renderer: OpaquePointer?
    private var started = false
    private var outputFormats: [AudioStreamBasicDescription] = []

    init(process: AudioProcess, gain: Float) throws {
        self.process = process
        do { try start(gain: gain) }
        catch { stop(); throw error }
    }
    func setGain(_ value: Float) {
        if let renderer { volume_set_gain(renderer, value) }
    }
    func healthError() -> String? {
        if let renderer, volume_has_fault(renderer) { return "音频缓冲格式发生变化，已恢复原始输出。" }
        guard let current = try? HAL.defaultOutput(), current == output else {
            return "默认输出设备已切换，已恢复原始输出。请重新开启控制。"
        }
        guard let formats = try? HAL.formats(output, scope: kAudioObjectPropertyScopeOutput),
              formats.count == outputFormats.count,
              zip(formats, outputFormats).allSatisfy({ a, b in
                  a.mSampleRate == b.mSampleRate && a.mFormatFlags == b.mFormatFlags &&
                  a.mChannelsPerFrame == b.mChannelsPerFrame && a.mBytesPerFrame == b.mBytesPerFrame
              }) else { return "输出格式已变化，已恢复原始输出。请重新开启控制。" }
        return nil
    }
    private func start(gain: Float) throws {
        // Check identity immediately before creating a tap: HAL object IDs and PIDs can be reused.
        guard try HAL.value(process.id, kAudioProcessPropertyPID, initial: pid_t(0)) == process.pid else {
            throw AudioFailure(message: "此进程已退出，请刷新后重试。")
        }
        output = try HAL.defaultOutput()
        outputFormats = try HAL.formats(output, scope: kAudioObjectPropertyScopeOutput)
        let outputLayout = try HAL.validate(outputFormats)
        let uid = try HAL.string(output, kAudioDevicePropertyDeviceUID)
        let description = CATapDescription(processes: [process.id], deviceUID: uid, stream: 0)
        description.name = "音量 · \(process.name)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try HAL.check(AudioHardwareCreateProcessTap(description, &tap), "创建进程音频 Tap")
        let tapFormat = try HAL.value(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        let tapLayout = try HAL.validate([tapFormat])
        guard outputFormats.count == 1, tapLayout.channels == outputLayout.channels,
              tapLayout.rate == outputLayout.rate else {
            throw AudioFailure(message: "此输出设备的流布局暂不支持。请切换到内置扬声器或普通立体声耳机。")
        }
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "音量 · \(process.pid)",
            kAudioAggregateDeviceUIDKey: "local.processvolume.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceSubDeviceListKey: [[
                kAudioSubDeviceUIDKey: uid,
                kAudioSubDeviceInputChannelsKey: 0
            ]],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        try HAL.check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate), "创建音频聚合设备")
        // Aggregate registration may finish asynchronously; keep the source unmuted until IO starts.
        var alive = false
        for _ in 0..<20 {
            if (try? HAL.value(aggregate, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))) == 1 {
                alive = true; break
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        guard alive else { throw AudioFailure(message: "音频设备尚未就绪，请重试。") }
        let input = try HAL.validate(HAL.formats(aggregate, scope: kAudioObjectPropertyScopeInput))
        let destination = try HAL.validate(HAL.formats(aggregate, scope: kAudioObjectPropertyScopeOutput))
        guard input.channels == tapLayout.channels, destination.channels == outputLayout.channels,
              input.rate == destination.rate else {
            throw AudioFailure(message: "聚合设备包含额外输入或不匹配的采样率，暂不支持此设备。")
        }
        guard let state = volume_create(gain, destination.rate) else {
            throw AudioFailure(message: "无法创建实时音量处理器。")
        }
        renderer = state
        try HAL.check(volume_register(aggregate, state, &io), "创建音频回调")
        try HAL.check(AudioDeviceStart(aggregate, io), "启动音频控制（请检查系统音频录制权限）")
        started = true
    }
    func stop() {
        // mutedWhenTapped restores the original path as soon as IO is stopped.
        if started { AudioDeviceStop(aggregate, io); started = false }
        var callbackDetached = io == nil
        if let io {
            callbackDetached = AudioDeviceDestroyIOProcID(aggregate, io) == noErr
            if callbackDetached { self.io = nil }
        }
        if aggregate != 0 {
            if AudioHardwareDestroyAggregateDevice(aggregate) == noErr {
                aggregate = 0
                self.io = nil
                callbackDetached = true
            }
        }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        if let renderer {
            if callbackDetached { volume_destroy(renderer); self.renderer = nil }
            else {
                // In a HAL teardown failure, leaking the tiny C context is safer than
                // releasing memory that a real-time callback could still access.
                volume_set_gain(renderer, 0)
                fputs("音量：HAL 回调清理失败，保留实时上下文以防止悬空访问。\n", stderr)
            }
        }
    }
    deinit { stop() }
}

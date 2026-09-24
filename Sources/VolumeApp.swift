import SwiftUI
import AppKit
import ServiceManagement

final class MixerModel: ObservableObject {
    @Published var processes: [AudioProcess] = []
    @Published var gains: [UInt32: Double] = [:]
    @Published var controlled: Set<UInt32> = []
    @Published var lastError: String?
    @Published var loginStatus = SMAppService.mainApp.status
    @Published var outputName = ""
    private var sessions: [UInt32: ProcessVolume] = [:]
    private var timer: Timer?
    private var terminationObserver: NSObjectProtocol?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.restore() }
    }
    func refresh() {
        loginStatus = SMAppService.mainApp.status
        do {
            let latest = try AudioProcess.list()
            for (id, session) in Array(sessions) {
                if !latest.contains(where: { $0.id == id && $0.pid == session.process.pid }) {
                    disable(id)
                    gains[id] = nil
                } else if let error = session.healthError() {
                    disable(id)
                    lastError = error
                }
            }
            processes = latest
            if let output = try? HAL.defaultOutput() {
                outputName = (try? HAL.string(output, kAudioObjectPropertyName)) ?? "默认输出"
            }
        } catch { lastError = error.localizedDescription }
    }
    func enable(_ process: AudioProcess) {
        guard sessions[process.id] == nil else { return }
        do {
            sessions[process.id] = try ProcessVolume(process: process, gain: Float(gains[process.id] ?? 1))
            controlled.insert(process.id)
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }
    func disable(_ id: UInt32) {
        sessions.removeValue(forKey: id)?.stop()
        controlled.remove(id)
    }
    func restore() {
        for id in Array(sessions.keys) { disable(id) }
    }
    func setGain(_ id: UInt32, _ gain: Double) {
        gains[id] = gain
        sessions[id]?.setGain(Float(gain))
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                } else if service.status != .enabled {
                    try service.register()
                    if service.status == .requiresApproval {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
            lastError = nil
        } catch { lastError = "自动启动：\(error.localizedDescription)" }
        // Display the actual system status, never an optimistic local preference.
        loginStatus = service.status
    }
}

struct MixerView: View {
    @ObservedObject var model: MixerModel
    @AppStorage("showIdleProcesses") private var showIdle = false
    @State private var showError = false

    private var rows: [AudioProcess] {
        model.processes.filter { showIdle || $0.running || model.controlled.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("音量").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(model.outputName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                if let error = model.lastError {
                    Button { showError.toggle() } label: {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看错误")
                    .popover(isPresented: $showError) {
                        Text(error).font(.callout).textSelection(.enabled).padding(16).frame(width: 280)
                    }
                }
                Menu {
                    Toggle("登录时自动启动", isOn: Binding(
                        get: { model.loginStatus == .enabled },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    if model.loginStatus == .requiresApproval {
                        Button("在系统设置中允许…") { SMAppService.openSystemSettingsLoginItems() }
                        Button("取消自动启动") { model.setLaunchAtLogin(false) }
                    }
                    Divider()
                    Toggle("显示空闲进程", isOn: $showIdle)
                    Button("全部恢复") { model.restore() }.disabled(model.controlled.isEmpty)
                    Divider()
                    Button("退出音量") {
                        model.restore()
                        NSApplication.shared.terminate(nil)
                    }
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 13))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("设置")
            }
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if rows.isEmpty {
                        Text("暂无音频").font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 72)
                    }
                    ForEach(rows) { process in
                        processRow(process)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: CGFloat(min(max(rows.count, 1), 5)) * 72)
        }
        .padding(16)
        .frame(width: 360)
    }
    private func processRow(_ process: AudioProcess) -> some View {
        let enabled = model.controlled.contains(process.id)
        let gain = model.gains[process.id] ?? 1
        return HStack(alignment: .top, spacing: 10) {
            Group {
                if let icon = NSRunningApplication(processIdentifier: process.pid)?.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "waveform").resizable().scaledToFit().padding(5)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28).padding(.top, 5)
            VStack(spacing: 4) {
                HStack {
                    Text(process.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .help("\(process.name) · PID \(process.pid)")
                    Spacer(minLength: 8)
                    Toggle("控制", isOn: Binding(get: { enabled }, set: { on in
                        if on { model.enable(process) } else { model.disable(process.id) }
                    }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .accessibilityLabel("控制 \(process.name)")
                }
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { model.gains[process.id] ?? 1 },
                                          set: { model.setGain(process.id, $0) }), in: 0...1)
                        .controlSize(.small).disabled(!enabled).accessibilityLabel("\(process.name) 音量")
                    Text("\(Int((gain * 100).rounded()))%")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 10)
        .frame(height: 72)
    }
}

@main
struct VolumeApp: App {
    @StateObject private var model = MixerModel()
    init() {
        if CommandLine.arguments.contains("--list") {
            do {
                for p in try AudioProcess.list() { print("\(p.pid)\t\(p.id)\t\(p.running ? "playing" : "idle")\t\(p.name)") }
                exit(0)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
    }
    var body: some Scene {
        MenuBarExtra {
            MixerView(model: model)
        } label: {
            Label("音量", systemImage: "slider.horizontal.3")
        }
        .menuBarExtraStyle(.window)
    }
}

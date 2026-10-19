import AppKit
import ServiceManagement
import SwiftUI

@main
struct OpenNTFSApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            Panel(model: model)
        } label: {
            Image(systemName: model.volumes.contains { $0.writable } ? "externaldrive.fill.badge.checkmark" : "externaldrive")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class Model: ObservableObject {
    @Published var volumes: [Volume] = []
    @Published var busy: Set<String> = []
    @Published var hasNTFS3G = Tools.path("ntfs-3g") != nil
    @Published var autoMount = UserDefaults.standard.object(forKey: "autoMount") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoMount, forKey: "autoMount") }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            do { try launchAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
            catch { alert("Launch at login", error.localizedDescription) }
        }
    }
    /// Volumes whose auto-mount failed or was cancelled; skipped until the user mounts them by hand.
    private var autoSkip: Set<String> = []

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh(auto: true) }
        }
        nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh(auto: true) }
    }

    func refresh(auto: Bool = false) async {
        volumes = await Task.detached { Disks.scan() }.value
        hasNTFS3G = Tools.path("ntfs-3g") != nil
        guard auto, autoMount, hasNTFS3G else { return }
        for v in volumes where v.mountPoint != nil && !v.writable && !autoSkip.contains(v.id) {
            run(v, auto: true) { try Ops.mountRW(v) }
        }
    }

    func run(_ v: Volume, auto: Bool = false, _ op: @escaping @Sendable () throws -> Void) {
        guard !busy.contains(v.id) else { return }
        busy.insert(v.id)
        Task {
            let result = await Task.detached { Result { try op() } }.value
            if case .failure(let e) = result {
                autoSkip.insert(v.id)
                if !auto || !e.localizedDescription.contains("canceled") {
                    alert("“\(v.name)” failed", hint(e.localizedDescription))
                }
            } else {
                autoSkip.remove(v.id)
            }
            busy.remove(v.id)
            await refresh()
        }
    }

    private func hint(_ msg: String) -> String {
        let m = msg.lowercased()
        if m.contains("hibernat") || m.contains("unclean") || m.contains("fast restart") {
            return msg + "\n\nWindows left this drive in a hibernated/unsafe state (Fast Startup). Fully shut down Windows (Shift + Shut Down), or use More → Repair. The drive was left mounted read-only."
        }
        return msg
    }

    func installDeps() {
        let script = "tell application \"Terminal\" to do script \"\(Tools.installCommand)\"\nactivate application \"Terminal\""
        _ = try? Shell.run("/usr/bin/osascript", ["-e", script])
    }

    func rename(_ v: Volume) {
        guard let name = prompt("Rename “\(v.name)”", "New volume label:", v.name), !name.isEmpty else { return }
        run(v) { try Ops.rename(v, to: name) }
    }

    func format(_ v: Volume) {
        guard let label = prompt("Erase “\(v.name)” as NTFS?",
                                 "ALL DATA on \(v.dev) (\(fmt(v.size))) will be permanently destroyed.\n\nNew volume label:",
                                 v.name, destructive: true), !label.isEmpty else { return }
        run(v) { try Ops.format(v, label: label) }
    }
}

// MARK: - Views

struct Panel: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("OpenNTFS").font(.headline)
                Spacer()
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh")
            }

            if !model.hasNTFS3G {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Writing to NTFS needs macFUSE + ntfs-3g (both free).").font(.callout)
                        Button("Install ntfs-3g…") { model.installDeps() }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if model.volumes.isEmpty {
                Text("No NTFS drives connected.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ForEach(model.volumes) { VolumeRow(v: $0, model: model) }
            }

            Divider()
            Toggle("Auto-mount NTFS drives read/write", isOn: $model.autoMount)
            Toggle("Launch at login", isOn: $model.launchAtLogin)
            Divider()
            Button("Quit OpenNTFS") { NSApp.terminate(nil) }.buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 340)
    }
}

struct VolumeRow: View {
    let v: Volume
    @ObservedObject var model: Model

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "externaldrive.fill")
                .font(.title)
                .foregroundStyle(v.writable ? Color.green : v.mountPoint == nil ? .secondary : .orange)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(v.name).bold().lineLimit(1)
                    Spacer()
                    Text(v.mountPoint == nil ? "Not mounted" : v.writable ? "Read/Write" : "Read-only")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((v.writable ? Color.green : .orange).opacity(0.2), in: Capsule())
                }
                if let free = v.free {
                    ProgressView(value: Double(max(v.size - free, 0)), total: Double(max(v.size, 1)))
                    Text("\(fmt(free)) free of \(fmt(v.size)) · \(v.id)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(fmt(v.size)) · \(v.id)").font(.caption).foregroundStyle(.secondary)
                }
                if model.busy.contains(v.id) {
                    ProgressView().controlSize(.small)
                } else {
                    HStack {
                        if !v.writable {
                            Button("Mount Read/Write") { model.run(v) { try Ops.mountRW(v) } }
                                .disabled(!model.hasNTFS3G)
                        }
                        if let mp = v.mountPoint {
                            Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: mp)) }
                        }
                        Button("Eject") { model.run(v) { try Ops.eject(v) } }
                        Menu("More") {
                            Button("Repair (clear dirty flag)") { model.run(v) { try Ops.repair(v) } }
                            Button("Rename…") { model.rename(v) }
                            Divider()
                            Button("Erase as NTFS…", role: .destructive) { model.format(v) }
                        }
                        .fixedSize()
                        .disabled(!model.hasNTFS3G)
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Helpers

func fmt(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

@MainActor
func alert(_ title: String, _ message: String) {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = title
    a.informativeText = message
    a.runModal()
}

@MainActor
func prompt(_ title: String, _ message: String, _ initial: String, destructive: Bool = false) -> String? {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = title
    a.informativeText = message
    a.alertStyle = destructive ? .critical : .informational
    let field = NSTextField(string: initial)
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    a.accessoryView = field
    a.addButton(withTitle: destructive ? "Erase" : "OK")
    a.addButton(withTitle: "Cancel")
    if destructive { a.buttons[0].hasDestructiveAction = true }
    a.window.initialFirstResponder = field
    return a.runModal() == .alertFirstButtonReturn ? field.stringValue.trimmingCharacters(in: .whitespaces) : nil
}

#if os(macOS)
import SwiftUI

struct ToolsView: View {
    @EnvironmentObject private var model: AppModel
    let bottle: Bottle

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Windows Tools").font(.headline)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(WineTool.allCases) { tool in
                            ProgramTile(title: tool.displayName, subtitle: nil, systemImage: tool.systemImage) {
                                model.launch(.tool(tool), in: bottle)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Bottle").font(.headline)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ProgramTile(title: "Open C: Drive", subtitle: "drive_c in Finder", systemImage: "internaldrive") {
                            model.openInFinder(bottle.driveC)
                        }
                        ProgramTile(title: "Simulate Reboot", subtitle: "Finishes installers that ask for a restart",
                                    systemImage: "arrow.triangle.2.circlepath") {
                            model.simulateReboot(bottle)
                        }
                        ProgramTile(title: "Force Quit", subtitle: "Stops every program in this bottle",
                                    systemImage: "xmark.octagon") {
                            model.forceQuit(bottle)
                        }
                        ProgramTile(title: "Duplicate Bottle", subtitle: "A full copy under a new name",
                                    systemImage: "plus.square.on.square") {
                            model.duplicate(bottle)
                        }
                        ProgramTile(title: "Show in Finder", subtitle: bottle.prefixURL.lastPathComponent, systemImage: "folder") {
                            model.reveal(bottle.prefixURL)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Remove").font(.headline)
                    Text(bottle.origin == .owned
                         ? "Moves this bottle and everything installed in it to the Trash."
                         : "Forgets this bottle in SteamXBridge. Its files\(bottle.linkedSource.map { " in \($0)" } ?? "") are not touched.")
                        .foregroundStyle(.secondary)
                    Button(bottle.origin == .owned ? "Move Bottle to Trash…" : "Remove from SteamXBridge…", role: .destructive) {
                        model.bottlePendingRemoval = bottle
                    }
                }
            }
            .padding(20)
        }
    }
}

struct LogsView: View {
    @EnvironmentObject private var model: AppModel
    let bottle: Bottle
    @State private var logs: [URL] = []
    @State private var selected: URL?
    @State private var text = ""

    var body: some View {
        HSplitView {
            List(logs, id: \.self, selection: $selected) { url in
                VStack(alignment: .leading, spacing: 2) {
                    Text(BottleStore.logTitle(for: url))
                        .lineLimit(1)
                    if let run = model.runs.first(where: { $0.logURL == url || $0.wineLogURL == url }) {
                        Text(run.isRunning ? "Running" : "Exited with status \(run.exitStatus ?? 0)")
                            .font(.caption)
                            .foregroundStyle(run.isRunning ? Color.green : (run.exitStatus == 0 ? Color.secondary : Color.orange))
                    } else {
                        Text(url.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(minWidth: 220, idealWidth: 260)

            VStack(spacing: 0) {
                if selected == nil {
                    Text(logs.isEmpty ? "No runs yet. Every program you start here gets a log." : "Select a log.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        Text(text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    Divider()
                    HStack {
                        Spacer()
                        Button("Reload") { load() }
                        Button("Show in Finder") { if let selected { model.reveal(selected) } }
                    }
                    .padding(10)
                }
            }
            .frame(minWidth: 360)
        }
        .onAppear(perform: refresh)
        .onChange(of: selected) { _, _ in load() }
        .onChange(of: model.runs.count) { _, _ in refresh() }
    }

    private func refresh() {
        // Include CrossOver's separate Wine logs next to SteamXBridge's run logs.
        let folder = model.store.logsDirectory.appendingPathComponent(bottle.id.uuidString, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        logs = files.filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        if selected == nil { selected = logs.first }
        load()
    }

    private func load() {
        guard let selected else { text = ""; return }
        text = ProcessRunner.readTail(of: selected, maxBytes: 256 * 1024)
    }

}
#endif

#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

struct BottleDetailView: View {
    @EnvironmentObject private var model: AppModel
    let bottleID: UUID
    @State private var tab: Tab = .programs
    @State private var choosingProgram = false
    @State private var choosingInstaller = false

    enum Tab: String, CaseIterable, Identifiable {
        case programs = "Programs", settings = "Settings", tools = "Tools", logs = "Logs"
        var id: String { rawValue }
    }

    var body: some View {
        if let bottle = model.bottle(bottleID) {
            VStack(spacing: 0) {
                BottleHeader(bottle: bottle)
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
                Divider()
                switch tab {
                case .programs: ProgramsView(bottle: bottle)
                case .settings: BottleSettingsView(bottle: bottle)
                case .tools: ToolsView(bottle: bottle)
                case .logs: LogsView(bottle: bottle)
                }
            }
            .navigationTitle(bottle.name)
            .toolbar {
                ToolbarItemGroup {
                    Button { choosingProgram = true } label: {
                        Label("Run Command…", systemImage: "play.rectangle")
                    }
                    .help("Run a Windows program (.exe, .msi, .bat, .lnk) in this bottle")
                    Button { choosingInstaller = true } label: {
                        Label("Install Software…", systemImage: "square.and.arrow.down")
                    }
                    .help("Run an installer in this bottle")
                    Button { model.refreshContents(bottle.id) } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
            .fileImporter(isPresented: $choosingProgram, allowedContentTypes: Self.windowsTypes) { result in
                guard case .success(let url) = result else { return }
                model.launch(.program(url, arguments: [], workingDirectory: nil), in: bottle)
            }
            .fileImporter(isPresented: $choosingInstaller, allowedContentTypes: Self.windowsTypes) { result in
                guard case .success(let url) = result else { return }
                model.launch(.program(url, arguments: [], workingDirectory: nil), in: bottle)
                tab = .programs
            }
            .onChange(of: model.runCommandBottleID) { _, id in
                if id == bottle.id {
                    choosingProgram = true
                    model.runCommandBottleID = nil
                }
            }
        }
    }

    /// .exe, .msi, .bat and .lnk, plus anything else so oddly named files can still be picked.
    static let windowsTypes: [UTType] = ["exe", "msi", "bat", "cmd", "lnk"]
        .compactMap { UTType(filenameExtension: $0) } + [.item]
}

struct BottleHeader: View {
    @EnvironmentObject private var model: AppModel
    let bottle: Bottle

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: bottle.isCrossOverBottle ? "wineglass.fill" : "wineglass")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(bottle.name)
                    .font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    Text(model.engine(for: bottle)?.name ?? (bottle.isCrossOverBottle ? "Needs CrossOver" : "No engine selected"))
                    Text("·")
                    Text(bottle.windowsVersion.displayName)
                    if let source = bottle.linkedSource {
                        Text("·")
                        Text("from \(source)")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let activity = model.activity[bottle.id] {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(activity).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(20)
    }
}

// MARK: Programs

struct ProgramsView: View {
    @EnvironmentObject private var model: AppModel
    let bottle: Bottle

    private var contents: BottleContents? { model.contents[bottle.id] }
    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(bottle.warnings(engine: model.engine(for: bottle)), id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !bottle.isInitialized {
                    Label("This bottle has not been initialized yet. Run a program or open Wine Configuration to set it up.",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }

                steamSection

                let running = model.runs(for: bottle.id).filter(\.isRunning)
                if !running.isEmpty {
                    section("Running") {
                        ForEach(running) { run in
                            HStack {
                                Image(systemName: "play.circle.fill").foregroundStyle(.green)
                                Text(run.name)
                                Text(run.startedAt, style: .relative).foregroundStyle(.secondary)
                                Spacer()
                                Button("Log") { model.reveal(run.logURL) }
                                    .buttonStyle(.borderless)
                            }
                        }
                        Button("Force Quit All") { model.forceQuit(bottle) }
                    }
                }

                if let programs = contents?.programs, !programs.isEmpty {
                    section("Installed Programs") {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(programs) { program in
                                ProgramTile(title: program.name, subtitle: program.target?.lastPathComponent,
                                            systemImage: "app.dashed") {
                                    run(program)
                                }
                                .contextMenu {
                                    Button("Run") { run(program) }
                                    if let target = program.target {
                                        Button("Show in Finder") { model.reveal(target) }
                                    }
                                }
                            }
                        }
                    }
                }

                if !bottle.pinnedPrograms.isEmpty {
                    section("Pinned") {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(bottle.pinnedPrograms) { pinned in
                                ProgramTile(title: pinned.name, subtitle: URL(fileURLWithPath: pinned.path).lastPathComponent,
                                            systemImage: "pin") {
                                    model.launch(.program(URL(fileURLWithPath: pinned.path), arguments: pinned.arguments,
                                                          workingDirectory: nil), in: bottle)
                                }
                                .contextMenu {
                                    Button("Show in Finder") { model.reveal(URL(fileURLWithPath: pinned.path)) }
                                    Button("Unpin") { model.unpin(pinned, in: bottle) }
                                }
                            }
                        }
                    }
                }

                if contents == nil {
                    ProgressView("Scanning bottle…")
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var steamSection: some View {
        if let contents {
            if let steam = contents.steam {
                section("Steam") {
                    HStack {
                        Button {
                            model.launch(.steamClient(steam), in: bottle)
                        } label: {
                            Label("Open Steam", systemImage: "gamecontroller")
                        }
                        .buttonStyle(.borderedProminent)
                        Text(contents.steamApps.isEmpty
                             ? "Install games from Steam; they appear here."
                             : "\(contents.steamApps.count) installed game\(contents.steamApps.count == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(contents.steamApps) { app in
                            SteamGameTile(app: app, steam: steam, bottle: bottle)
                        }
                    }
                }
            } else {
                section("Steam") {
                    HStack(spacing: 14) {
                        Image(systemName: "gamecontroller")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Steam for Windows is not installed in this bottle.")
                            Text("Windows-only games need the Windows Steam client running in the same bottle.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Install Steam") { model.installSteam(in: bottle.id) }
                            .disabled(model.activity[bottle.id] != nil)
                    }
                    .padding(14)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func run(_ program: InstalledProgram) {
        if let target = program.target {
            let arguments = program.arguments.map { $0.split(separator: " ").map(String.init) } ?? []
            model.launch(.program(target, arguments: arguments, workingDirectory: program.workingDirectory), in: bottle)
        } else {
            model.launch(.program(program.shortcut, arguments: [], workingDirectory: nil), in: bottle)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
    }
}

struct ProgramTile: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Run \(title)")
    }
}

struct SteamGameTile: View {
    @EnvironmentObject private var model: AppModel
    let app: SteamApp
    let steam: SteamInstallation
    let bottle: Bottle
    @State private var showingInfo = false

    private var entry: GameCompatibility.Entry? { GameCompatibility.lookup(appID: app.appID, name: app.name) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "gamecontroller.fill")
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let entry {
                        CompatibilityBadge(rating: entry.rating)
                    }
                    if !app.isFullyInstalled {
                        Text("Not fully installed")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if let size = app.sizeOnDisk {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            if entry != nil {
                Button { showingInfo.toggle() } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .help("Compatibility notes")
                .popover(isPresented: $showingInfo, arrowEdge: .bottom) {
                    if let entry { CompatibilityPopover(entry: entry, bottle: bottle) }
                }
            }
            Button("Play") { model.launch(.steamGame(appID: app.appID, steam: steam), in: bottle) }
                .disabled(!app.isFullyInstalled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
        .contextMenu {
            Button("Play through Steam") { model.launch(.steamGame(appID: app.appID, steam: steam), in: bottle) }
            Button("Run Executable Directly") {
                if let exe = ExecutableFinder.candidates(in: app.installDirectory, preferredName: app.name).first {
                    model.launch(.program(exe, arguments: [], workingDirectory: nil), in: bottle)
                } else {
                    model.alert = AppAlert(title: "No executable found", message: "No game executable was found in \(app.installDirectory.path).")
                }
            }
            Button("Show in Finder") { model.reveal(app.installDirectory) }
            if let entry, entry.recommendation != nil {
                Divider()
                Button("Apply Recommended Settings") { model.applyRecommendation(entry, to: bottle) }
            }
        }
    }
}

struct CompatibilityBadge: View {
    let rating: GameCompatibility.Rating

    var body: some View {
        Text(rating.label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch rating {
        case .native: return .blue
        case .runsWell: return .green
        case .playable: return .orange
        case .blocked: return .red
        }
    }
}

struct CompatibilityPopover: View {
    @EnvironmentObject private var model: AppModel
    let entry: GameCompatibility.Entry
    let bottle: Bottle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(entry.title).font(.headline)
                CompatibilityBadge(rating: entry.rating)
            }
            if let antiCheat = entry.antiCheat {
                Text("Anti-cheat: \(antiCheat)").font(.callout).foregroundStyle(.secondary)
            }
            if let problem = GameCompatibility.assessment(of: entry, engine: model.engine(for: bottle)) {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(entry.note)
                .fixedSize(horizontal: false, vertical: true)
            if entry.recommendation != nil {
                Button("Apply Recommended Settings to \(bottle.name)") { model.applyRecommendation(entry, to: bottle) }
            }
            Text("Last checked \(entry.asOf). Game updates can change this.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 380)
    }
}
#endif

#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let bottle = model.selectedBottle {
                BottleDetailView(bottleID: bottle.id)
                    .id(bottle.id)
            } else if model.isLoading {
                ProgressView("Loading bottles…")
            } else {
                WelcomeView()
            }
        }
        .sheet(isPresented: $model.showingNewBottle) {
            NewBottleSheet()
                .environmentObject(model)
        }
        .alert(model.alert?.title ?? "", isPresented: Binding(
            get: { model.alert != nil },
            set: { if !$0 { model.alert = nil } }
        ), presenting: model.alert) { _ in
            Button("OK", role: .cancel) { model.alert = nil }
        } message: { alert in
            Text(alert.message)
        }
        .alert(model.launchRequest?.title ?? "", isPresented: Binding(
            get: { model.launchRequest != nil },
            set: { if !$0 { model.launchRequest = nil } }
        ), presenting: model.launchRequest) { request in
            if request.canLaunchAnyway {
                Button("Launch Anyway") { model.confirmLaunch(request) }
            }
            Button(request.canLaunchAnyway ? "Cancel" : "OK", role: .cancel) { model.launchRequest = nil }
        } message: { request in
            Text(request.message)
        }
        .alert("Quit programs to apply these settings?", isPresented: Binding(
            get: { model.pendingApply != nil },
            set: { if !$0 { model.pendingApply = nil } }
        ), presenting: model.pendingApply) { pending in
            Button("Quit Programs and Apply") { model.confirmPendingApply(pending) }
            Button("Not Now", role: .cancel) { model.pendingApply = nil }
        } message: { pending in
            Text("Programs are running in \(pending.updated.name), including Steam if it is open. These settings only take effect when every program in the bottle has quit. Your changes stay in the Settings tab until you apply them.")
        }
        .confirmationDialog(
            removalTitle,
            isPresented: Binding(get: { model.bottlePendingRemoval != nil }, set: { if !$0 { model.bottlePendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: model.bottlePendingRemoval
        ) { bottle in
            Button(bottle.origin == .owned ? "Move to Trash" : "Remove", role: .destructive) {
                model.remove(bottle)
                model.bottlePendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { model.bottlePendingRemoval = nil }
        } message: { bottle in
            Text(bottle.origin == .owned
                 ? "The bottle and everything installed in it move to the Trash."
                 : "SteamXBridge forgets this bottle. Its files stay where they are\(bottle.linkedSource.map { " (in \($0))" } ?? "").")
        }
        .overlay(alignment: .bottom) {
            if let activity = model.globalActivity {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(activity)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 12)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

extension RootView {
    private var removalTitle: String {
        guard let bottle = model.bottlePendingRemoval else { return "" }
        return bottle.origin == .owned ? "Move \"\(bottle.name)\" to the Trash?" : "Remove \"\(bottle.name)\" from SteamXBridge?"
    }
}

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var importingFolder = false

    var body: some View {
        List(selection: $model.selection) {
            Section("Bottles") {
                if model.bottles.isEmpty, !model.isLoading {
                    Text("No bottles yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.bottles) { bottle in
                    BottleRow(bottle: bottle)
                        .tag(bottle.id)
                        .contextMenu {
                            Button("Open C: Drive") { model.openInFinder(bottle.driveC) }
                            Button("Show in Finder") { model.reveal(bottle.prefixURL) }
                            Button("Duplicate") { model.duplicate(bottle) }
                                .disabled(model.isBusy(bottle))
                            Divider()
                            Button(bottle.origin == .owned ? "Move to Trash…" : "Remove from SteamXBridge…", role: .destructive) {
                                model.bottlePendingRemoval = bottle
                            }
                            .disabled(model.isBusy(bottle))
                        }
                }
            }
            if !model.externalBottles.isEmpty {
                Section("Found on this Mac") {
                    ForEach(model.externalBottles) { external in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(external.name)
                                Text(external.hasSteam ? "\(external.source) · Steam installed" : external.source)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Add") { model.link(external) }
                                .buttonStyle(.borderless)
                                .help("Use this bottle in SteamXBridge without moving or changing it")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("New Bottle…") { model.showingNewBottle = true }
                    Button("Add Existing Bottle Folder…") { importingFolder = true }
                    Divider()
                    Button("Rescan This Mac") { model.reload() }
                } label: {
                    Label("Add Bottle", systemImage: "plus")
                }
            }
        }
        .fileImporter(isPresented: $importingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.linkFolder(url) }
        }
    }
}

struct BottleRow: View {
    @EnvironmentObject private var model: AppModel
    let bottle: Bottle

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: bottle.isCrossOverBottle ? "wineglass.fill" : "wineglass")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(bottle.name)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.activity[bottle.id] != nil {
                ProgressView().controlSize(.small)
            } else if model.runs(for: bottle.id).contains(where: \.isRunning) {
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(.green)
                    .help("A program is running in this bottle")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if let engine = model.engine(for: bottle) { return engine.name }
        return bottle.isCrossOverBottle ? "Needs CrossOver" : "No engine"
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wineglass")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("Run Windows games and apps in bottles")
                .font(.title2.weight(.semibold))
            Text("A bottle is a self-contained Windows environment. Create one, install Steam into it, and play your Windows games, or add a bottle you already have from CrossOver or Whisky.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            if model.engines.isEmpty {
                EngineHelpView()
                    .frame(maxWidth: 520)
            } else {
                Button("New Bottle…") { model.showingNewBottle = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(40)
    }
}

/// Explains how to get a Wine engine when none is installed.
struct EngineHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("No Wine engine found", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("SteamXBridge drives a Wine engine that you install separately:")
            VStack(alignment: .leading, spacing: 6) {
                Text("• **CrossOver 26** (CodeWeavers, paid with a free trial): the most compatible engine, and the only one that runs HELLDIVERS 2.")
                Text("• **Game Porting Toolkit** (Apple's D3DMetal, via Gcenx's free build): `brew install --cask gcenx/wine/game-porting-toolkit`")
                Text("• **Wine** (WineHQ builds by Gcenx): download Wine Stable from github.com/Gcenx/macOS_Wine_builds")
            }
            .font(.callout)
            Text("Then choose Steam X Bridge > Settings… to rescan engines.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

#endif

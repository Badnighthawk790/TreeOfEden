#if os(macOS)
import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if let compat = viewModel.compatibility {
                    compatibilityBanner(compat)
                }

                gameSection
                translationSection
                performanceSection

                guidanceSection
                customEnvSection
                actionBar

                Text(viewModel.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Steam X Bridge")
                .font(.largeTitle.weight(.bold))
            Text("Configure and launch x86 Steam games through a translation layer tuned for Apple Silicon.")
                .foregroundStyle(.secondary)
        }
    }

    private func compatibilityBanner(_ entry: GameCompatibility.Entry) -> some View {
        let tint: Color
        let icon: String
        switch entry.status {
        case .blocked:
            tint = .red
            icon = "xmark.octagon.fill"
        case .risky:
            tint = .orange
            icon = "exclamationmark.triangle.fill"
        case .playable:
            tint = .green
            icon = "checkmark.seal.fill"
        case .unknown:
            tint = .secondary
            icon = "questionmark.circle"
        }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text("\(entry.title): \(entry.status.label)")
                    .font(.headline)
            }
            .foregroundStyle(tint)

            if let antiCheat = entry.antiCheat {
                Text("Anti-cheat: \(antiCheat)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(entry.note)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.5)))
    }

    private var gameSection: some View {
        GroupBox("Game") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Profile name", text: $viewModel.profile.name)
                TextField("Steam App ID (optional, enables compatibility checks)", text: $viewModel.profile.steamAppID)
                TextField("Game executable (.exe) path", text: $viewModel.profile.gameExecutablePath)
                TextField("Wine prefix path (optional)", text: $viewModel.profile.winePrefixPath)
                TextField("Runtime binary (GPTK / CrossOver / Whisky wine64)", text: $viewModel.runtimeBinary)
            }
            .textFieldStyle(.roundedBorder)
            .padding(.vertical, 4)
        }
    }

    private var translationSection: some View {
        GroupBox("Translation backend") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Backend", selection: $viewModel.profile.backend) {
                    ForEach(TranslationBackend.allCases) { Text($0.displayName).tag($0) }
                }
                Text(viewModel.profile.backend.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("CPU sync", selection: $viewModel.profile.syncPrimitive) {
                    ForEach(SyncPrimitive.allCases) { Text($0.displayName).tag($0) }
                }
                if viewModel.profile.backend == .wineDXVK {
                    Toggle("Async shader compilation (DXVK)", isOn: $viewModel.profile.useAsyncShaders)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var performanceSection: some View {
        GroupBox("Performance (M2 MacBook Air)") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ForEach(PerformancePreset.allCases) { preset in
                        Button(preset.displayName) { viewModel.applyPreset(preset) }
                            .help(preset.summary)
                    }
                }
                Picker("Upscaler", selection: $viewModel.profile.upscaler) {
                    ForEach(Upscaler.allCases) { Text($0.displayName).tag($0) }
                }
                VStack(alignment: .leading) {
                    Text("Render resolution scale: \(viewModel.profile.resolutionScalePercent)%")
                    Slider(
                        value: Binding(
                            get: { Double(viewModel.profile.resolutionScalePercent) },
                            set: { viewModel.profile.resolutionScalePercent = Int($0) }
                        ),
                        in: 50...100,
                        step: 1
                    )
                }
                Stepper("Frame cap: \(viewModel.profile.frameLimit) FPS", value: $viewModel.profile.frameLimit, in: 30...240, step: 5)
                Toggle("Show FPS overlay (Metal / DXVK HUD)", isOn: $viewModel.profile.showFPSOverlay)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var guidanceSection: some View {
        if !viewModel.profile.validationWarnings.isEmpty {
            calloutList(
                title: "Check these",
                items: viewModel.profile.validationWarnings,
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }
        if !viewModel.profile.setupReminders.isEmpty {
            calloutList(
                title: "Setup reminders",
                items: viewModel.profile.setupReminders,
                systemImage: "lightbulb",
                tint: .blue
            )
        }
    }

    private func calloutList(title: String, items: [String], systemImage: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                    Text(item)
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    private var customEnvSection: some View {
        GroupBox("Advanced — custom environment variables") {
            VStack(alignment: .leading, spacing: 6) {
                Text("One KEY=VALUE per line. These override the generated defaults.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $viewModel.profile.customEnv)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 100)
                    .border(Color.gray.opacity(0.2))
            }
            .padding(.vertical, 4)
        }
    }

    private var actionBar: some View {
        HStack {
            Button("Load Profile…") { openProfile() }
            Button("Save Profile…") { saveProfile() }
            Spacer()
            Button("Launch Game") { viewModel.launchGame() }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.profile.isValid)
        }
    }

    private func saveProfile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(viewModel.profile.name.isEmpty ? "steam-game" : viewModel.profile.name).json"
        if panel.runModal() == .OK, let url = panel.url {
            try? viewModel.saveProfile(to: url)
        }
    }

    private func openProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            try? viewModel.loadProfile(from: url)
        }
    }
}
#endif

#if os(macOS)
import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Steam X Bridge")
                .font(.largeTitle.weight(.bold))
            Text("Create launch profiles to run x86 Steam games through a Wine runtime tuned for Apple Silicon.")
                .foregroundStyle(.secondary)

            Form {
                TextField("Profile name", text: $viewModel.profile.name)
                TextField("Steam App ID (optional)", text: $viewModel.profile.steamAppID)
                TextField("Game executable path", text: $viewModel.profile.gameExecutablePath)
                TextField("Wine prefix path (optional)", text: $viewModel.profile.protonPrefixPath)
                TextField("Runtime binary (Whisky/CrossOver wine64)", text: $viewModel.runtimeBinary)

                HStack {
                    Toggle("Use DXVK", isOn: $viewModel.profile.useDXVK)
                    Toggle("Async shaders", isOn: $viewModel.profile.useAsyncShaders)
                    Toggle("ESync", isOn: $viewModel.profile.esync)
                    Toggle("FSync", isOn: $viewModel.profile.fsync)
                }

                Stepper(value: $viewModel.profile.frameLimit, in: 30...240, step: 5) {
                    Text("Frame cap: \(viewModel.profile.frameLimit) FPS")
                }

                VStack(alignment: .leading) {
                    Text("Custom environment variables (one KEY=VALUE per line)")
                    TextEditor(text: $viewModel.profile.customEnv)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 120)
                        .border(Color.gray.opacity(0.2))
                }
            }

            HStack {
                Button("Load Profile…") { openProfile() }
                Button("Save Profile…") { saveProfile() }
                Spacer()
                Button("Launch Game") { viewModel.launchGame() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.profile.isValid)
            }

            Text(viewModel.statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
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

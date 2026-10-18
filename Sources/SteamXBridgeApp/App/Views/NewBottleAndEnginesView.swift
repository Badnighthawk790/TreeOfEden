#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

struct NewBottleSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Steam"
    @State private var engineID: String?
    @State private var windowsVersion: WindowsVersion = .win10
    @State private var installSteam = true

    private var engines: [WineEngine] { AppModel.ordered(model.engines) }
    private var engine: WineEngine? { engines.first { $0.id == engineID } ?? engines.first }
    private var nameIsValid: Bool { (try? BottleStore.validatedName(name)) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Bottle")
                .font(.title2.weight(.semibold))
            if engines.isEmpty {
                EngineHelpView()
            } else {
                Form {
                    TextField("Name", text: $name)
                    Picker("Engine", selection: Binding(get: { engine?.id ?? "" }, set: { engineID = $0 })) {
                        ForEach(engines) { Text($0.name).tag($0.id) }
                    }
                    Picker("Windows version", selection: $windowsVersion) {
                        ForEach(WindowsVersion.allCases) { Text($0.displayName).tag($0) }
                    }
                    Toggle("Install Steam for Windows after creating it", isOn: $installSteam)
                }
                .formStyle(.grouped)

                if let engine {
                    Text(explanation(for: engine))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    guard let engine else { return }
                    model.createBottle(named: name, engine: engine, windowsVersion: windowsVersion, installSteam: installSteam)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(engine == nil || !nameIsValid)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func explanation(for engine: WineEngine) -> String {
        if engine.isCrossOver {
            return "CrossOver creates and manages this bottle (64-bit, in CrossOver's Bottles folder), so CrossOver itself can open it too. Requires a CrossOver license or trial."
        }
        var text = "SteamXBridge creates a 64-bit Wine prefix for this bottle."
        if engine.supports(.d3dMetal) { text += " Direct3D 11/12 runs through D3DMetal." }
        if engine.needsRosetta { text += " This engine runs under Rosetta 2." }
        return text
    }
}

struct EnginesSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var choosingEngine = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wine Engines")
                .font(.title3.weight(.semibold))
            Text("SteamXBridge runs Windows programs with Wine engines installed on this Mac. It never bundles or modifies them.")
                .foregroundStyle(.secondary)

            if model.engines.isEmpty {
                EngineHelpView()
            } else {
                List {
                    ForEach(AppModel.ordered(model.engines)) { engine in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(engine.name).font(.headline)
                                Text(details(engine))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(engine.loaderPath)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            if model.customEngines.contains(where: { $0.id == engine.id }) {
                                Button("Remove") { model.removeCustomEngine(engine) }
                                    .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if !Rosetta.isInstalled, model.engines.contains(where: \.needsRosetta) {
                Label("Rosetta 2 is not installed, and these engines need it. Run \"\(Rosetta.installCommand)\" in Terminal.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Add Engine…") { choosingEngine = true }
                Button("Rescan") { model.reload() }
                Spacer()
            }
        }
        .padding(20)
        .fileImporter(isPresented: $choosingEngine, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { model.addCustomEngine(at: url) }
        }
    }

    private func details(_ engine: WineEngine) -> String {
        var parts = [engine.kind.displayName]
        if engine.architectures.isEmpty {
            parts.append(engine.isCrossOver ? "CrossOver wrapper" : "script")
        } else {
            parts.append(engine.architectures.map(\.description).joined(separator: " + "))
        }
        let features: [(EngineFeature, String)] = [(.d3dMetal, "D3DMetal"), (.dxmt, "DXMT"), (.dxvk, "DXVK"),
                                                    (.msync, "MSync"), (.esync, "ESync"), (.dlssMetalFX, "DLSS→MetalFX")]
        let supported = features.filter { engine.supports($0.0) }.map(\.1)
        if !supported.isEmpty { parts.append(supported.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}
#endif

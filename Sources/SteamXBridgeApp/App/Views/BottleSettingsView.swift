#if os(macOS)
import SwiftUI

/// Edits a draft of the bottle; nothing touches the bottle until Apply, so
/// registry and winecfg changes are not run on every keystroke.
struct BottleSettingsView: View {
    @EnvironmentObject private var model: AppModel
    let bottle: Bottle
    @State private var draft: Bottle

    init(bottle: Bottle) {
        self.bottle = bottle
        _draft = State(initialValue: bottle)
    }

    private var engines: [WineEngine] { model.compatibleEngines(for: bottle) }
    private var engine: WineEngine? {
        engines.first { $0.id == draft.engineID } ?? engines.first
    }
    private var hasChanges: Bool { draft != bottle }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Bottle") {
                    TextField("Name", text: $draft.name)
                    if engines.isEmpty {
                        Text(bottle.isCrossOverBottle ? "Install CrossOver to run this CrossOver bottle." : "No compatible engine is installed.")
                            .foregroundStyle(.orange)
                    } else {
                        Picker("Engine", selection: Binding(
                            get: { engine?.id ?? "" },
                            set: { draft.engineID = $0 }
                        )) {
                            ForEach(engines) { engine in
                                Text(engine.name).tag(engine.id)
                            }
                        }
                    }
                    Picker("Windows version", selection: $draft.windowsVersion) {
                        ForEach(WindowsVersion.allCases) { Text($0.displayName).tag($0) }
                    }
                    LabeledContent("Location") {
                        Button(bottle.prefixPath) { model.reveal(bottle.prefixURL) }
                            .buttonStyle(.link)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if let engine {
                    graphicsSection(engine)
                    performanceSection(engine)
                }

                Section {
                    ForEach(draft.settings.environment) { item in
                        let variable = environmentBinding(item.id)
                        HStack {
                            TextField("NAME", text: variable.name)
                                .font(.body.monospaced())
                            Text("=")
                            TextField("value", text: variable.value)
                                .font(.body.monospaced())
                            if !item.name.isEmpty, !LaunchPlanner.isValidEnvironmentName(item.name) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help("Not a valid variable name; it will be ignored.")
                            } else if LaunchPlanner.reservedVariables.contains(item.name) {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.secondary)
                                    .help("SteamXBridge sets this itself; it will be ignored.")
                            }
                            Button(role: .destructive) {
                                draft.settings.environment.removeAll { $0.id == item.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("Add Variable") {
                        draft.settings.environment.append(EnvironmentVariable(name: "", value: ""))
                    }
                } header: {
                    Text("Environment Variables")
                } footer: {
                    Text("Applied to every program started in this bottle.")
                }

                Section("Troubleshooting") {
                    Toggle("Detailed Wine logging", isOn: $draft.settings.debugLogging)
                    Text("Writes Wine's debug channels to each run's log (Logs tab). Slower; turn it off when you are done.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("This Mac's GPU — \(model.gpu.marketingName)") {
                    Text(model.gpu.classLabel)
                        .foregroundStyle(.secondary)
                    ForEach(model.gpu.featureStatuses) { status in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(status.isAvailable ? Color.green : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(status.feature)
                                Text(status.status)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if bottle.isCrossOverBottle {
                    Text("Settings are written to the bottle's cxbottle.conf; quit running programs first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Changes apply to programs started after you click Apply.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revert") { draft = bottle }
                    .disabled(!hasChanges)
                Button("Apply") {
                    var updated = draft
                    updated.name = (try? BottleStore.validatedName(updated.name)) ?? bottle.name
                    model.save(updated)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasChanges)
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .onChange(of: bottle) { _, newValue in
            if !hasChanges { draft = newValue }
        }
    }

    /// A binding to one variable looked up by ID, so deleting rows never leaves
    /// a text field holding a stale index.
    private func environmentBinding(_ id: UUID) -> Binding<EnvironmentVariable> {
        Binding(
            get: { draft.settings.environment.first { $0.id == id } ?? EnvironmentVariable(id: id, name: "", value: "") },
            set: { updated in
                if let index = draft.settings.environment.firstIndex(where: { $0.id == id }) {
                    draft.settings.environment[index] = updated
                }
            }
        )
    }

    private func graphicsSection(_ engine: WineEngine) -> some View {
        Section("Graphics") {
            Picker("Renderer", selection: $draft.settings.graphics) {
                ForEach(engine.graphicsBackends) { backend in
                    Text(backend == .automatic ? "Automatic (\(engine.automaticGraphicsDescription))" : backend.displayName)
                        .tag(backend)
                }
            }
            Text(draft.settings.graphics.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            if draft.settings.graphics == .dxvk, !engine.isCrossOver {
                Text("DXVK's files are copied into the bottle the next time a program starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if engine.supports(.dlssMetalFX) {
                Toggle("DLSS powered by MetalFX", isOn: $draft.settings.dlssMetalFX)
                Text("Turn on DLSS in the game; it is upscaled with MetalFX (D3DMetal or DXMT, macOS 26).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if engine.supports(.d3dMetal) {
                Picker("DirectX ray tracing", selection: $draft.settings.rayTracing) {
                    ForEach(RayTracingMode.allCases) { Text($0.displayName).tag($0) }
                }
                .disabled(!model.gpu.hasHardwareRayTracing)
                Text(model.gpu.hasHardwareRayTracing
                     ? "Automatic keeps D3DMetal's default (on for M3 and newer)."
                     : "This Mac has no hardware ray tracing (M3 and newer), so DXR stays off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Metal Performance HUD", isOn: $draft.settings.metalHUD)
            Toggle("High Resolution Mode", isOn: $draft.settings.highResolutionMode)
            Text("Renders at full Retina resolution (192 DPI). Sharper, but much heavier on the GPU; keep it off on a MacBook Air.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func performanceSection(_ engine: WineEngine) -> some View {
        Section("Performance") {
            if engine.supports(.msync) {
                Toggle("MSync", isOn: $draft.settings.msync)
            }
            if engine.supports(.esync), !(engine.supports(.msync) && draft.settings.msync) {
                Toggle("ESync", isOn: $draft.settings.esync)
            }
            if !engine.isCrossOver {
                Toggle("Steam compatibility switches", isOn: $draft.settings.steamCompatibilityFlags)
                Text("Starts Steam with -noverifyfiles -no-cef-sandbox -cef-single-process. Can help Steam's window on WineHQ builds, where it may still appear black (an open Wine bug); CrossOver handles Steam itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Advertise AVX to programs", isOn: $draft.settings.advertiseAVX)
            Text("Lets Rosetta report AVX/AVX2 (macOS 15 or later). Some games, such as HELLDIVERS 2, refuse to start without it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
#endif

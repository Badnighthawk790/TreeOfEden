#if os(macOS)
import SwiftUI

/// Edits a draft of the bottle; nothing touches the bottle until Apply, so
/// registry and winecfg changes are not run on every keystroke.
struct BottleSettingsView: View {
    @EnvironmentObject private var model: AppModel
    let bottle: Bottle

    /// The edited copy lives in the model, so edits survive switching tabs or bottles.
    private var draft: Bottle { model.settingsDrafts[bottle.id] ?? bottle }
    private var draftBinding: Binding<Bottle> {
        Binding(
            get: { model.settingsDrafts[bottle.id] ?? bottle },
            set: { edited in updateDraft { $0 = edited } }
        )
    }

    /// Edits the draft; a draft equal to the saved bottle is dropped.
    private func updateDraft(_ change: (inout Bottle) -> Void) {
        var edited = draft
        change(&edited)
        model.settingsDrafts[bottle.id] = AppModel.sameSettings(edited, bottle) ? nil : edited
    }

    private var engines: [WineEngine] { model.compatibleEngines(for: bottle) }
    private var engine: WineEngine? {
        engines.first { $0.id == draft.engineID } ?? engines.first
    }
    private var hasChanges: Bool { !AppModel.sameSettings(draft, bottle) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Bottle") {
                    TextField("Name", text: draftBinding.name)
                    if engines.isEmpty {
                        if bottle.isCrossOverBottle {
                            Text("Install CrossOver to run this CrossOver bottle.")
                                .foregroundStyle(.orange)
                        } else if model.runtimeStatus == .ready {
                            Text("No compatible engine is installed.")
                                .foregroundStyle(.orange)
                        } else {
                            RuntimeStatusView()
                        }
                    } else {
                        Picker("Engine", selection: Binding(
                            get: { engine?.id ?? "" },
                            set: { id in updateDraft { $0.engineID = id } }
                        )) {
                            ForEach(engines) { engine in
                                Text(engine.name).tag(engine.id)
                            }
                        }
                    }
                    Picker("Windows version", selection: draftBinding.windowsVersion) {
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
                                updateDraft { $0.settings.environment.removeAll { $0.id == item.id } }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("Add Variable") {
                        updateDraft { $0.settings.environment.append(EnvironmentVariable(name: "", value: "")) }
                    }
                } header: {
                    Text("Environment Variables")
                } footer: {
                    Text("Applied to every program started in this bottle.")
                }

                Section("Troubleshooting") {
                    Toggle("Detailed Wine logging", isOn: draftBinding.settings.debugLogging)
                    Text("Writes Wine's debug channels to each run's log (Logs tab). Slower; turn it off when you are done.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("This Mac — \(model.gpu.marketingName)") {
                    Text([model.gpu.classLabel, model.system.summary].filter { !$0.isEmpty }.joined(separator: " · "))
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
                Button("Revert") { model.settingsDrafts[bottle.id] = nil }
                    .disabled(!hasChanges)
                Button("Apply") {
                    // Normalize the name in the draft too, so once saved the draft
                    // matches and Apply/Revert turn off.
                    let name = (try? BottleStore.validatedName(draft.name)) ?? bottle.name
                    updateDraft { $0.name = name }
                    // Copy only the editable fields onto the current bottle, so
                    // pins added meanwhile are kept.
                    model.save(AppModel.withSettings(of: draft, on: bottle))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasChanges)
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }

    /// A binding to one variable looked up by ID, so deleting rows never leaves
    /// a text field holding a stale index.
    private func environmentBinding(_ id: UUID) -> Binding<EnvironmentVariable> {
        Binding(
            get: { draft.settings.environment.first { $0.id == id } ?? EnvironmentVariable(id: id, name: "", value: "") },
            set: { updated in
                updateDraft { bottle in
                    if let index = bottle.settings.environment.firstIndex(where: { $0.id == id }) {
                        bottle.settings.environment[index] = updated
                    }
                }
            }
        )
    }

    private func graphicsSection(_ engine: WineEngine) -> some View {
        Section("Graphics") {
            Picker("Renderer", selection: draftBinding.settings.graphics) {
                ForEach(engine.graphicsBackends) { backend in
                    Text(backend == .automatic ? "Automatic (\(engine.automaticGraphicsDescription))" : backend.displayName)
                        .tag(backend)
                }
            }
            Text(draft.settings.graphics.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let layer = engine.layer(for: draft.settings.graphics)?.layer {
                Text("\(layer == .dxmt ? "DXMT" : "DXVK")'s files are copied into the bottle the next time a program starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if runsDXMT(engine) {
                Toggle("MetalFX upscaling", isOn: draftBinding.settings.metalFXUpscaling)
                if draft.settings.metalFXUpscaling {
                    LabeledContent("Upscale factor") {
                        HStack {
                            Slider(value: draftBinding.settings.metalFXScale, in: 1.0...2.0, step: 0.25)
                                .frame(maxWidth: 200)
                            Text(String(format: "%.2f×", draft.settings.metalFXScale))
                                .monospacedDigit()
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                }
                Text(metalFXExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Frame rate limit", selection: draftBinding.settings.frameRateLimit) {
                    Text("Off").tag(0)
                    ForEach(frameRateChoices, id: \.self) { Text(frameRateLabel($0)).tag($0) }
                }
                Text("DXMT does not wait for the display on its own, so menus and light scenes can run at hundreds of frames per second. A limit stops that heat, and a fanless Mac holds its speed for longer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if engine.supports(.dlssMetalFX) {
                Toggle("DLSS powered by MetalFX", isOn: draftBinding.settings.dlssMetalFX)
                Text("Turn on DLSS in the game; it is upscaled with MetalFX (D3DMetal or DXMT, macOS 26).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if engine.supports(.d3dMetal) {
                Picker("DirectX ray tracing", selection: draftBinding.settings.rayTracing) {
                    ForEach(RayTracingMode.allCases) { Text($0.displayName).tag($0) }
                }
                .disabled(!model.gpu.hasHardwareRayTracing)
                Text(model.gpu.hasHardwareRayTracing
                     ? "Automatic keeps D3DMetal's default (on for M3 and newer)."
                     : "This Mac has no hardware ray tracing (M3 and newer), so DXR stays off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Metal Performance HUD", isOn: draftBinding.settings.metalHUD)
            Toggle("High Resolution Mode", isOn: draftBinding.settings.highResolutionMode)
            Text("Renders at full Retina resolution (192 DPI). Sharper, but much heavier on the GPU; keep it off on a MacBook Air.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// True when the draft's renderer is DXMT, whose own upscaler and frame cap apply.
    private func runsDXMT(_ engine: WineEngine) -> Bool {
        PerformanceTuning.runsDXMT(draft.settings, engine: engine)
    }

    /// Limits this display can pace evenly, plus the bottle's own value when
    /// it was chosen on another display.
    private var frameRateChoices: [Int] {
        let choices = FrameRateCap.choices(refreshRate: model.display.refreshRate)
        let current = draft.settings.frameRateLimit
        return current > 0 && !choices.contains(current) ? (choices + [current]).sorted() : choices
    }

    private func frameRateLabel(_ limit: Int) -> String {
        let refresh = model.display.refreshRate
        let effective = FrameRateCap.effectiveRate(limit: limit, refreshRate: refresh)
        if effective != limit { return "\(limit) fps (runs at \(effective) on this \(refresh) Hz display)" }
        return limit == refresh ? "\(limit) fps (this display's refresh rate)" : "\(limit) fps"
    }

    /// What the upscale factor does on this display, in its own numbers.
    private var metalFXExplanation: String {
        let display = model.display
        let scale = draft.settings.metalFXScale
        var text = "The game renders at the resolution you choose in it, and MetalFX enlarges each frame by this factor."
        if display.isRetina, display.width > 0 {
            let w = Int((Double(display.width) * scale).rounded()), h = Int((Double(display.height) * scale).rounded())
            text += " On this display, 2× is pixel-exact: a game at \(display.width)×\(display.height) comes out at \(display.width * 2)×\(display.height * 2)."
            if scale != 2 { text += " At \(String(format: "%.2f", scale))× it comes out at \(w)×\(h) and macOS scales the rest." }
            text += " For more speed, pick a lower resolution in the game."
        } else if !display.isRetina {
            text += " This display is not Retina, so upscaling only helps when the game runs below the display's resolution."
        }
        return text
    }

    /// The settings recommended for this Mac, when the draft differs from them.
    private func optimizedSettings(_ engine: WineEngine) -> BottleSettings? {
        let optimized = PerformanceTuning.optimized(draft.settings, engine: engine, display: model.display)
        return optimized == draft.settings ? nil : optimized
    }

    private func performanceSection(_ engine: WineEngine) -> some View {
        Section("Performance") {
            if let optimized = optimizedSettings(engine) {
                Button("Optimize for This Mac") { updateDraft { $0.settings = optimized } }
                Text(model.gpu.isEntryLevel
                     ? "Recommended on this Mac: MetalFX upscaling at 2×, a frame-rate limit at the display's refresh rate, and High Resolution Mode and detailed logging off. Review the changes, then click Apply."
                     : "Sets MetalFX upscaling at 2×, a frame-rate limit at the display's refresh rate, and High Resolution Mode and detailed logging off. Meant for slower Macs; review the changes, then click Apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.performanceNotes(for: bottle, settings: draft.settings)) { note in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title)
                        Text(note.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: note.kind == .warning ? "exclamationmark.triangle.fill" : "lightbulb")
                        .foregroundStyle(note.kind == .warning ? Color.orange : Color.secondary)
                }
            }
            if engine.supports(.msync) {
                Toggle("MSync", isOn: draftBinding.settings.msync)
            }
            if engine.supports(.esync), !(engine.supports(.msync) && draft.settings.msync) {
                Toggle("ESync", isOn: draftBinding.settings.esync)
            }
            if !engine.isCrossOver {
                Toggle("Steam compatibility switches", isOn: draftBinding.settings.steamCompatibilityFlags)
                Text("Starts Steam with \(LaunchPlanner.steamCompatibilityArguments.joined(separator: " ")). Try it when Steam's window stays black on this engine (an open Wine bug); CrossOver handles Steam itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Advertise AVX to programs", isOn: draftBinding.settings.advertiseAVX)
            Text("Lets Rosetta report AVX/AVX2 (macOS 15 or later). Some games, such as HELLDIVERS 2, refuse to start without it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
#endif

#if os(macOS)
import SwiftUI

@main
struct SteamXBridgeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        // A single main window: bottles are shared state, so duplicate windows
        // would only fight over the same selection.
        Window("Steam X Bridge", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands { AppCommands(model: model) }

        Settings {
            EnginesSettingsView()
                .environmentObject(model)
                .frame(width: 680, height: 480)
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Bottle…") { model.showingNewBottle = true }
                .keyboardShortcut("n")
        }
        CommandMenu("Bottle") {
            Button("Run Command…") { model.runCommandBottleID = model.selection }
                .keyboardShortcut("r")
                .disabled(model.selectedBottle == nil)
            Button("Install Steam") {
                if let id = model.selection { model.installSteam(in: id) }
            }
            .disabled(model.selectedBottle == nil)
            Divider()
            Button("Open C: Drive") {
                if let bottle = model.selectedBottle { model.openInFinder(bottle.driveC) }
            }
            .disabled(model.selectedBottle == nil)
            Button("Simulate Reboot") {
                if let bottle = model.selectedBottle { model.simulateReboot(bottle) }
            }
            .disabled(model.selectedBottle == nil)
            Button("Force Quit Bottle") {
                if let bottle = model.selectedBottle { model.forceQuit(bottle) }
            }
            .keyboardShortcut(".", modifiers: [.command, .option])
            .disabled(model.selectedBottle == nil)
            Divider()
            Button("Refresh") { model.reload() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}
#endif

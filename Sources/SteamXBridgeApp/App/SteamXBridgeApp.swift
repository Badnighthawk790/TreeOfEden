#if os(macOS)
import AppKit
import SwiftUI

@main
struct SteamXBridgeApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A single main window: bottles are shared state, so duplicate windows
        // would only fight over the same selection.
        Window("Steam X Bridge", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { appDelegate.model = model }
        }
        .commands { AppCommands(model: model) }

        Settings {
            EnginesSettingsView()
                .environmentObject(model)
                .frame(width: 680, height: 480)
        }
    }
}

/// Asks before quitting while SteamXBridge is in the middle of something
/// (installing Steam, creating or duplicating a bottle, applying settings).
/// Games and programs keep running after the app quits, so they do not block it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let work = model?.workInProgress, !work.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "SteamXBridge is still working"
        alert.informativeText = work.joined(separator: "\n") + "\n\nQuitting now interrupts it, and the bottle may be left half set up."
        alert.addButton(withTitle: "Keep Working")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    /// An operation is already running in the selected bottle.
    private var selectedBusy: Bool { model.selection.map { model.activity[$0] != nil } ?? false }

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
            .disabled(model.selectedBottle == nil || selectedBusy)
            Divider()
            Button("Open C: Drive") {
                if let bottle = model.selectedBottle { model.openInFinder(bottle.driveC) }
            }
            .disabled(model.selectedBottle == nil)
            Button("Simulate Reboot") {
                if let bottle = model.selectedBottle { model.simulateReboot(bottle) }
            }
            .disabled(model.selectedBottle == nil || selectedBusy)
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

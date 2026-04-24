#if os(macOS)
import SwiftUI

@main
struct SteamXBridgeApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup("Steam X Bridge") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 740, minHeight: 560)
        }
    }
}
#endif

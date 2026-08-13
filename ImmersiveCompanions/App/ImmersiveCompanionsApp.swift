/*
Abstract:
The app itself: one window, and the menu commands that open a file into it.
*/

import SwiftUI

// MARK: - The app

@main
struct ImmersiveCompanionsApp: App {
    @State private var queue = ConversionQueue()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// One window, not a `WindowGroup`.
    ///
    /// A `WindowGroup` is the multi-window scene, and the app declares itself a viewer of
    /// movie files — so every Open With, every drop on the Dock icon and every `open -a`
    /// arriving while it was already running opened *another* window. All of them onto the
    /// same queue, since that lives here and there is only ever one of it, so what you got
    /// was several identical lists stacked on top of each other.
    ///
    /// There is one queue because the encoder is one piece of hardware. A single window is
    /// the honest shape for that.
    var body: some Scene {
        Window("Immersive Companions", id: "converter") {
            ContentView()
                .environment(queue)
                .onAppear { delegate.queue = queue }
        }
        .defaultSize(width: 680, height: 500)
        .windowResizability(.contentMinSize)
    }
}

/// Takes files opened from outside the window: dropped on the Dock icon, sent with Open
/// With, or handed over by `open -a`. The drop zone is the obvious way in; this is the one
/// that fits into everything else on the Mac.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor weak var queue: ConversionQueue?

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        queue?.add(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

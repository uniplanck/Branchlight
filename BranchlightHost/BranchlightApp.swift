import AppKit
import Combine
import SwiftUI

final class BranchlightAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }

        sender.windows
            .first(where: { $0.canBecomeMain || $0.canBecomeKey })?
            .makeKeyAndOrderFront(nil)
        return true
    }
}

@main
struct BranchlightApp: App {
    @NSApplicationDelegateAdaptor(BranchlightAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 500)
                .onAppear {
                    model.consumeFinderRequest()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.consumeFinderRequest()
                }
        }
        .windowResizability(.contentMinSize)
    }
}

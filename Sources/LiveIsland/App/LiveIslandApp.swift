import LiveIslandCore
import SwiftUI
import os

@main
struct LiveIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel().environmentObject(appDelegate.model)
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = IslandModel()
    private var island: IslandController?
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        let island = IslandController(model: model)
        island.show()
        self.island = island
        // `kill` and `pkill` send SIGTERM: quit properly, so the media adapter goes too.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    /// liveisland:// links, e.g. from Shortcuts: open, close, settings, timer/<minutes>.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "liveisland" {
            Logger(subsystem: "com.aissam.liveisland", category: "url").notice("Open \(url.absoluteString, privacy: .public)")
            let parts = [url.host].compactMap { $0 } + url.pathComponents.filter { $0 != "/" }
            switch parts.first?.lowercased() {
            case "open": model.expand()
            case "close": model.collapse()
            case "settings": model.openSettings()
            case "timer":
                if let minutes = parts.dropFirst().first.flatMap(Double.init), minutes > 0 { model.startTimer(minutes: minutes) }
            default: break
            }
        }
    }
}

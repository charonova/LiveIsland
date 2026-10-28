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

    /// liveisland:// links, e.g. from Shortcuts: open[/media|agents|activity|accounts[/claude|codex]], close,
    /// settings[/general|island|media|agents|accounts[/claude|codex][/accounts|automatic|console]|updates|about], update[/install], timer/<minutes>.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "liveisland" {
            Logger(subsystem: "com.aissam.liveisland", category: "url").notice("Open \(url.absoluteString, privacy: .public)")
            let parts = [url.host].compactMap { $0 } + url.pathComponents.filter { $0 != "/" }
            let detail = parts.dropFirst().first?.lowercased()
            switch parts.first?.lowercased() {
            case "open":
                // open/accounts/codex picks the Codex list.
                if let kind = parts.dropFirst(2).first.flatMap({ AgentKind(rawValue: $0.lowercased()) }) { model.accountsKind = kind }
                model.expand(on: detail.flatMap { IslandTab(rawValue: $0.capitalized) })
            case "close": model.collapse()
            case "update":
                // update: check now and show the result; update/install also installs what it finds.
                let install = detail == "install"
                model.openSettings(.updates)
                Task {
                    await model.updater.check()
                    if install { await model.updater.install() }
                }
            // settings/accounts/codex/console picks the tool and the tab; settings/codex is
            // what 1.7 called the Codex page.
            case "settings":
                let rest = parts.dropFirst(2).joined(separator: "/")
                if detail == "codex" {
                    model.openSettings(.accounts, anchor: "codex" + (rest.isEmpty ? "" : "/" + rest))
                } else {
                    model.openSettings(detail.flatMap(SettingsSection.init(rawValue:)) ?? .general, anchor: rest.isEmpty ? nil : rest)
                }
            case "timer":
                if let minutes = parts.dropFirst().first.flatMap(Double.init), minutes > 0 { model.startTimer(minutes: minutes) }
            default: break
            }
        }
    }
}

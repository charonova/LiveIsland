import AppKit
import Darwin
import LiveIslandCore

/// Finds the running Claude Code and Codex processes: the folder each started in, the terminal
/// it's attached to, and the app around it (VS Code, Cursor, Antigravity, Terminal…), so the
/// island can jump straight to a session.
enum SessionHosts {
    struct Found {
        var kind: AgentKind
        var host: SessionHost
    }

    /// One read of the whole process table, then a few calls per agent found.
    static func scan() -> [Found] {
        var parents: [pid_t: pid_t] = [:]
        var agents: [(pid: pid_t, kind: AgentKind, tty: String?)] = []
        for process in allProcesses() {
            let pid = process.kp_proc.p_pid
            parents[pid] = process.kp_eproc.e_ppid
            var comm = process.kp_proc.p_comm
            let name = withUnsafeBytes(of: &comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let kind: AgentKind
            switch name {
            case "claude": kind = .claude
            case "codex": kind = .codex
            // Claude Code's native install runs ~/.local/share/claude/versions/2.1.308, so the
            // kernel calls it "2.1.308"; it's still started as "claude".
            case _ where isVersionNumber(name) && firstArgument(of: pid).map({ ($0 as NSString).lastPathComponent }) == "claude":
                kind = .claude
            default: continue
            }
            var tty: String?
            let device = process.kp_eproc.e_tdev
            if device != -1, let path = devname(device, S_IFCHR) {
                tty = "/dev/" + String(cString: path)
            }
            agents.append((pid, kind, tty))
        }

        var found: [Found] = []
        for agent in agents {
            guard let folder = workingDirectory(of: agent.pid),
                  let app = hostApp(of: agent.pid, parents: parents)
            else { continue }
            found.append(Found(kind: agent.kind, host: SessionHost(bundleIdentifier: app.bundleIdentifier, processID: app.pid,
                                                                   tty: agent.tty, folder: folder)))
        }
        return found
    }

    private static func isVersionNumber(_ name: String) -> Bool {
        !name.isEmpty && name.contains(".") && name.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// argv[0], from the kernel's copy of the process's arguments.
    private static func firstArgument(of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        // argc, then the executable path, padding, and argv[0].
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        let start = index
        while index < size, buffer[index] != 0 { index += 1 }
        return start < index ? String(decoding: buffer[start..<index], as: UTF8.self) : nil
    }

    /// Every process, with its parent and terminal; unlike per-process calls this also covers
    /// root's processes, such as the `login` between Terminal and its shell.
    private static func allProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        size += size / 4  // Room for processes started in between.
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return [] }
        return Array(processes.prefix(size / MemoryLayout<kinfo_proc>.stride))
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty || path == "/" ? nil : path
    }

    /// The nearest ancestor that is a regular app: the shell's terminal, or the editor whose
    /// helper process runs the integrated terminal.
    private static func hostApp(of pid: pid_t, parents: [pid_t: pid_t]) -> (bundleIdentifier: String, pid: pid_t)? {
        var current = parents[pid]
        for _ in 0..<16 {
            guard let process = current, process > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: process), app.activationPolicy == .regular,
               let bundle = app.bundleIdentifier {
                return (bundle, process)
            }
            current = parents[process]
        }
        return nil
    }
}

/// Bringing a session's app forward, as close to the session as each app allows.
@MainActor
enum SessionJump {
    /// Editors built on VS Code keep their open windows in a JSON file under Application Support.
    static let editors: [String: String] = [
        "com.microsoft.VSCode": "Code",
        "com.microsoft.VSCodeInsiders": "Code - Insiders",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.google.antigravity": "Antigravity",
        "com.exafunction.windsurf": "Windsurf",
        "com.vscodium": "VSCodium",
    ]

    private static let queue = DispatchQueue(label: "com.aissam.liveisland.jump", qos: .userInitiated)

    static func go(to host: SessionHost, cwd: String?) {
        if let support = editors[host.bundleIdentifier] {
            openEditorWindow(host, support: support, cwd: cwd)
        } else if let tty = host.tty, let script = terminalScript(for: host.bundleIdentifier, tty: tty) {
            queue.async {
                var error: NSDictionary?
                NSAppleScript(source: script)?.executeAndReturnError(&error)
                if error != nil { DispatchQueue.main.async { activate(host) } }
            }
        } else {
            activate(host)
        }
    }

    private static func activate(_ host: SessionHost) {
        NSRunningApplication(processIdentifier: host.processID)?.activate()
    }

    /// Opening a folder that's already open in the editor brings its window forward. Opening
    /// any other folder would make a new window, so then just bring the editor forward.
    private static func openEditorWindow(_ host: SessionHost, support: String, cwd: String?) {
        let folders = openFolders(support: support)
        let target = [cwd, host.folder].compactMap { $0 }.lazy.compactMap { SessionHost.window(for: $0, among: folders) }.first
        guard let target, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: host.bundleIdentifier) else {
            return activate(host)
        }
        NSWorkspace.shared.open([URL(fileURLWithPath: target)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func openFolders(support: String) -> [String] {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(support)/User/globalStorage/storage.json")
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = object["windowsState"] as? [String: Any]
        else { return [] }
        let entries = [windows["lastActiveWindow"]].compactMap { $0 } + ((windows["openedWindows"] as? [Any]) ?? [])
        return entries.compactMap { entry in
            guard let folder = (entry as? [String: Any])?["folder"] as? String, let url = URL(string: folder), url.isFileURL else { return nil }
            return url.path
        }
    }

    /// Terminal and iTerm2 can select the exact tab by its terminal device.
    private static func terminalScript(for bundle: String, tty: String) -> String? {
        switch bundle {
        case "com.apple.Terminal":
            return """
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                        end if
                    end repeat
                end repeat
                activate
            end tell
            """
        case "com.googlecode.iterm2":
            return """
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                select t
                                select s
                            end if
                        end repeat
                    end repeat
                end repeat
                activate
            end tell
            """
        default:
            return nil
        }
    }
}

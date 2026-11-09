import Foundation
import Darwin

/// Finds the dev servers running on this Mac.
///
/// The full scan reads the process table: every TCP socket listening on this Mac, which process
/// owns it, the folder it runs in, and from there the git checkout, branch and worktree. That needs
/// Browsa outside the App Sandbox, which hides other processes and your project folders.
///
/// Inside the sandbox it falls back to knocking on the ports dev servers usually use and asking
/// each what it is over HTTP. That finds the server and its framework, not its branch.
enum RadarScanner {
    /// One dev server, as found.
    struct Found: Sendable, Hashable {
        var port: Int
        var project: String
        var branch: String
        var framework: String
        var isWorktree = false
        /// The checkout's top folder, when known.
        var root: String?
        var pid: pid_t?
        /// How to run it again: the job that started it (`pnpm dev`, say), with its folder and
        /// environment.
        var launch: Launch?
    }

    struct Launch: Sendable, Hashable {
        var executable: String
        var arguments: [String]
        var directory: String
        var environment: [String: String]
        /// The job's first process, the one typed in the terminal.
        var leader: pid_t
        /// The job's process group, for Stop: what Ctrl-C in its terminal would reach. Only when
        /// the job leads its own group, so Stop never reaches whatever ran it.
        var processGroup: pid_t?
    }

    enum Mode: Sendable { case processes, ports }

    /// The full scan works when the process table is readable. In the sandbox it reads as empty.
    static let mode: Mode = {
        if ProcessInfo.processInfo.environment["BROWSA_RADAR_PORTS_ONLY"] != nil { return .ports }
        return proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0) > 0 ? .processes : .ports
    }()

    /// `ignoring` Browsa's own ports, which are never a dev server.
    static func scan(ignoring ownPorts: Set<Int>) async -> [Found] {
        switch mode {
        case .processes: return ProcessScan.run(ignoring: ownPorts)
        case .ports: return await PortScan.run(ignoring: ownPorts)
        }
    }
}

// MARK: - From the process table

private enum ProcessScan {
    /// Not dev servers even when started from a project folder.
    static let ignoredNames: Set<String> = [
        "postgres", "redis-server", "mysqld", "mongod", "memcached", "rapportd", "ControlCenter",
        "Browsa", "Browsa Dev", "com.docker.backend", "ssh",
    ]

    static func run(ignoring ownPorts: Set<Int>) -> [RadarScanner.Found] {
        let me = getpid()
        let uid = getuid()
        var byPid: [pid_t: Set<Int>] = [:]
        for pid in allPids() where pid > 0 && pid != me {
            let ports = listeningPorts(pid)
            if !ports.isEmpty { byPid[pid] = ports }
        }
        var found: [RadarScanner.Found] = []
        var seenPorts = Set<Int>()
        for (pid, ports) in byPid {
            guard let info = bsdInfo(pid), info.pbi_uid == uid else { continue }
            let name = comm(info)
            guard !ignoredNames.contains(name), let cwd = workingDirectory(pid), isProjectFolder(cwd) else { continue }
            let args = arguments(pid)
            let git = Git.lookup(cwd)
            let fromArgs = Framework.guess(args: args.argv)
            let framework = fromArgs ?? Framework.guess(name: name)
            // A folder that isn't a checkout counts only when its command plainly runs a dev server.
            guard git != nil || fromArgs != nil else { continue }
            let usable = ports.subtracting(ownPorts).subtracting(seenPorts)
            guard let port = mainPort(usable) else { continue }
            seenPorts.insert(port)
            found.append(.init(
                port: port,
                project: git?.project ?? URL(fileURLWithPath: cwd).lastPathComponent,
                branch: git?.branch ?? "",
                framework: framework ?? name,
                isWorktree: git?.isWorktree ?? false,
                root: git?.root ?? cwd,
                pid: pid,
                launch: launch(for: pid, info: info, fallback: args, cwd: cwd)))
        }
        return tidy(found)
    }

    /// One row per server, not per socket: a dev server's helpers (Wrangler's inspector and
    /// workerd, say) listen on ephemeral ports from the same checkout. Within a checkout, ephemeral
    /// ports go when a regular one is there, and each framework keeps its main port.
    static func tidy(_ found: [RadarScanner.Found]) -> [RadarScanner.Found] {
        let ephemeral = 49152...65535
        var out: [RadarScanner.Found] = []
        for (_, group) in Dictionary(grouping: found, by: { $0.root ?? "" }) {
            let regular = group.filter { !ephemeral.contains($0.port) }
            let kept = regular.isEmpty ? group : regular
            for (_, same) in Dictionary(grouping: kept, by: { "\($0.branch)|\($0.framework)" }) {
                let ports = Set(same.map(\.port))
                if let port = mainPort(ports), let f = same.first(where: { $0.port == port }) { out.append(f) }
            }
        }
        return out.sorted { $0.port < $1.port }
    }

    /// A server with several sockets (an HMR or inspector port beside the page) shows the one
    /// you'd open: a well-known dev port if it has one, else the lowest.
    static func mainPort(_ ports: Set<Int>) -> Int? {
        ports.first(where: PortScan.commonPorts.contains) ?? ports.min()
    }

    /// Apps launched from the Dock run in `/`; dev servers run in a project.
    static func isProjectFolder(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        guard path != "/", path != home, path.hasPrefix(home) || path.hasPrefix("/Volumes/") || path.hasPrefix("/private/tmp") || path.hasPrefix("/tmp") else { return false }
        // Not app support folders, and not hidden ones like ~/.claude-mem where daemons live.
        return !path.contains(".app/") && !path.hasPrefix(home + "/Library/") && !path.hasPrefix(home + "/.")
    }

    // MARK: libproc

    static func allPids() -> [pid_t] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.stride + 64)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        return Array(pids.prefix(Int(got) / MemoryLayout<pid_t>.stride))
    }

    static func listeningPorts(_ pid: pid_t) -> Set<Int> {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
        guard got > 0 else { return [] }
        var ports = Set<Int>()
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let r = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
            guard r > 0, info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN, reachableFromLocalhost(tcp.tcpsi_ini) else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if port > 0 { ports.insert(port) }
        }
        return ports
    }

    /// Bound to loopback or to every address, so `localhost` reaches it.
    static func reachableFromLocalhost(_ ini: in_sockinfo) -> Bool {
        if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
            let addr = UInt32(bigEndian: ini.insi_laddr.ina_46.i46a_addr4.s_addr)
            return addr == 0 || addr >> 24 == 127
        }
        var v6 = ini.insi_laddr.ina_6
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        let loopback: [UInt8] = Array(repeating: 0, count: 15) + [1]
        return bytes.allSatisfy { $0 == 0 } || bytes == loopback
    }

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return r == MemoryLayout<proc_bsdinfo>.size ? info : nil
    }

    static func comm(_ info: proc_bsdinfo) -> String {
        var name = info.pbi_name
        let s = withUnsafeBytes(of: &name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        if !s.isEmpty { return s }
        var c = info.pbi_comm
        return withUnsafeBytes(of: &c) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let r = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard r > 0 else { return nil }
        var path = info.pvi_cdir.vip_path
        let s = withUnsafeBytes(of: &path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return s.isEmpty ? nil : s
    }

    struct Args { var executable = ""; var argv: [String] = []; var environment: [String: String] = [:] }

    /// The process's command line and environment, from KERN_PROCARGS2.
    static func arguments(_ pid: pid_t) -> Args {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return Args() }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return Args() }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        func next() -> String? {
            while i < size, buf[i] == 0 { i += 1 }
            guard i < size else { return nil }
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            return String(decoding: buf[start..<i], as: UTF8.self)
        }
        var out = Args()
        out.executable = next() ?? ""
        for _ in 0..<argc { if let a = next() { out.argv.append(a) } }
        while let e = next() {
            guard let eq = e.firstIndex(of: "=") else { continue }
            out.environment[String(e[..<eq])] = String(e[e.index(after: eq)...])
        }
        return out
    }

    /// The job that started the server: the topmost ancestor in its process group, which is the
    /// command typed in the terminal (`pnpm dev`) rather than the node process it spawned.
    static func launch(for pid: pid_t, info: proc_bsdinfo, fallback: Args, cwd: String) -> RadarScanner.Launch? {
        let group = pid_t(info.pbi_pgid)
        var leader = pid
        var current = info
        for _ in 0..<12 {
            let parent = pid_t(current.pbi_ppid)
            guard parent > 1, let p = bsdInfo(parent), pid_t(p.pbi_pgid) == group else { break }
            leader = parent
            current = p
        }
        let args = leader == pid ? fallback : arguments(leader)
        guard !args.executable.isEmpty, !args.argv.isEmpty else { return nil }
        return .init(executable: args.executable, arguments: Array(args.argv.dropFirst()),
                     directory: workingDirectory(leader) ?? cwd, environment: args.environment,
                     leader: leader, processGroup: leader == group ? group : nil)
    }
}

// MARK: - Git

enum Git {
    struct Info: Hashable { var root: String; var project: String; var branch: String; var isWorktree: Bool }

    /// The checkout a folder is in: its project (the main checkout's folder name, for a worktree
    /// too), branch, and whether it's a linked worktree.
    static func lookup(_ folder: String) -> Info? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: folder).standardizedFileURL
        for _ in 0..<20 {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    return Info(root: dir.path, project: dir.lastPathComponent, branch: branch(gitDir: dotGit), isWorktree: false)
                }
                // A worktree: `.git` is a file saying "gitdir: <main>/.git/worktrees/<name>".
                guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                      let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
                let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                let gitDir = URL(fileURLWithPath: path, relativeTo: dir).standardizedFileURL
                let parts = gitDir.pathComponents
                // <main>/.git/worktrees/<name>: the project is <main>'s name.
                if let i = parts.lastIndex(of: "worktrees"), i >= 2, parts[i - 1] == ".git" {
                    return Info(root: dir.path, project: parts[i - 2], branch: branch(gitDir: gitDir), isWorktree: true)
                }
                // A submodule, or something else with a .git file: treat it as its own checkout.
                return Info(root: dir.path, project: dir.lastPathComponent, branch: branch(gitDir: gitDir), isWorktree: false)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    static func branch(gitDir: URL) -> String {
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return "" }
        if head.hasPrefix("ref: refs/heads/") { return String(head.dropFirst("ref: refs/heads/".count)) }
        // Detached: a short commit, as git shows it.
        return String(head.prefix(7))
    }
}

// MARK: - Framework

enum Framework {
    /// What a command line is running, by the tool it names.
    static func guess(args: [String]) -> String? {
        let line = args.joined(separator: " ").lowercased()
        let rules: [(String, String)] = [
            ("storybook", "Storybook"), ("next", "Next.js"), ("nuxt", "Nuxt"), ("astro", "Astro"),
            ("remix", "Remix"), ("@sveltejs/kit", "SvelteKit"), ("vite", "Vite"), ("wrangler", "Wrangler"),
            ("workerd", "Wrangler"), ("webpack", "webpack"), ("react-scripts", "Create React App"),
            ("parcel", "Parcel"), ("eleventy", "Eleventy"), ("gatsby", "Gatsby"), ("docusaurus", "Docusaurus"),
            ("expo", "Expo"), ("ng serve", "Angular"), ("@angular/cli", "Angular"), ("rails", "Rails"),
            ("puma", "Rails"), ("manage.py runserver", "Django"), ("flask", "Flask"), ("uvicorn", "Uvicorn"),
            ("gunicorn", "Gunicorn"), ("fastapi", "FastAPI"), ("http.server", "Python"), ("hugo", "Hugo"),
            ("jekyll", "Jekyll"), ("php", "PHP"), ("live-server", "Live Server"), ("serve", "serve"),
        ]
        for (needle, label) in rules where matches(line, needle) { return label }
        return nil
    }

    /// The runtime, when the command line didn't say more.
    static func guess(name: String) -> String? {
        switch name {
        case "node": return "Node"
        case "bun": return "Bun"
        case "deno": return "Deno"
        case "go": return "Go"
        default: return nil
        }
    }

    /// The needle as a word or path piece, so "next" doesn't match "nextcloud-sync".
    private static func matches(_ line: String, _ needle: String) -> Bool {
        var range = line.startIndex..<line.endIndex
        while let r = line.range(of: needle, range: range) {
            let before = r.lowerBound == line.startIndex ? " " : line[line.index(before: r.lowerBound)]
            let after = r.upperBound == line.endIndex ? " " : line[r.upperBound]
            let edge: (Character) -> Bool = { " /.@-_:".contains($0) }
            if edge(before) && edge(after) { return true }
            range = r.upperBound..<line.endIndex
        }
        return false
    }
}

// MARK: - From the ports, in the sandbox

enum PortScan {
    /// Where dev servers usually start.
    static let commonPorts: Set<Int> = Set(
        Array(3000...3010) + Array(4000...4005) + [4200, 4321, 4322, 4173, 4174, 5000, 5001]
            + Array(5173...5180) + [5500, 5501, 6006, 6007] + Array(8000...8010) + Array(8080...8090)
            + [8787, 8788, 8888, 9000, 9001, 9002, 1313, 1234, 19006, 24678]
    )

    static func run(ignoring ownPorts: Set<Int>) async -> [RadarScanner.Found] {
        let ports = commonPorts.subtracting(ownPorts).sorted()
        return await withTaskGroup(of: RadarScanner.Found?.self) { group in
            for port in ports { group.addTask { await probe(port) } }
            var out: [RadarScanner.Found] = []
            for await f in group { if let f { out.append(f) } }
            return out.sorted { $0.port < $1.port }
        }
    }

    static func probe(_ port: Int) async -> RadarScanner.Found? {
        guard isListening(port) else { return nil }
        // Ask what it is. Anything that doesn't answer HTTP isn't a page to open.
        var request = URLRequest(url: URL(string: "http://localhost:\(port)/")!, timeoutInterval: 1.5)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        let server = (http.value(forHTTPHeaderField: "Server") ?? "").lowercased()
        // AirPlay Receiver sits on 5000 and 7000.
        if server.contains("airtunes") { return nil }
        let body = String(decoding: data.prefix(64_000), as: UTF8.self)
        let framework = fingerprint(headers: http, body: body)
        let title = body.range(of: "<title>(.*?)</title>", options: [.regularExpression, .caseInsensitive])
            .map { String(body[$0]).replacingOccurrences(of: "</?title>", with: "", options: [.regularExpression, .caseInsensitive]) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // "Checkout | Acme" or "Acme — Home": the first part names it.
        let shortTitle = title?.components(separatedBy: CharacterSet(charactersIn: "|—–·")).first?
            .trimmingCharacters(in: .whitespaces)
        let name = await packageName(port) ?? shortTitle.flatMap { $0.isEmpty ? nil : String($0.prefix(40)) }
        return .init(port: port, project: name ?? framework ?? "localhost", branch: "", framework: framework ?? "Web server")
    }

    /// Vite and friends serve the project folder, package.json included.
    static func packageName(_ port: Int) async -> String? {
        let request = URLRequest(url: URL(string: "http://localhost:\(port)/package.json")!, timeoutInterval: 1)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String, !name.isEmpty else { return nil }
        return name
    }

    static func fingerprint(headers: HTTPURLResponse, body: String) -> String? {
        let powered = (headers.value(forHTTPHeaderField: "X-Powered-By") ?? "").lowercased()
        let lower = body.lowercased()
        if powered.contains("next") || lower.contains("/_next/") || lower.contains("__next") { return "Next.js" }
        if lower.contains("storybook") { return "Storybook" }
        if lower.contains("/@vite/client") { return lower.contains("astro") ? "Astro" : "Vite" }
        if lower.contains("__nuxt") { return "Nuxt" }
        if lower.contains("sveltekit") { return "SvelteKit" }
        if lower.contains("astro") { return "Astro" }
        if lower.contains("webpack") { return "webpack" }
        if powered.contains("express") { return "Express" }
        let server = (headers.value(forHTTPHeaderField: "Server") ?? "").lowercased()
        if server.contains("simplehttp") { return "Python" }
        if server.contains("puma") || server.contains("webrick") { return "Rails" }
        if server.contains("uvicorn") { return "Uvicorn" }
        if server.contains("wsgiserver") { return "Django" }
        return nil
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.timeoutIntervalForRequest = 1.5
        return URLSession(configuration: c)
    }()

    /// A quick connect to 127.0.0.1 and ::1: Node binds `localhost` to either.
    static func isListening(_ port: Int) -> Bool {
        connects(family: AF_INET, port: port) || connects(family: AF_INET6, port: port)
    }

    private static func connects(family: Int32, port: Int) -> Bool {
        let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var result: Int32
        if family == AF_INET {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
            result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        } else {
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = in_port_t(UInt16(port).bigEndian)
            addr.sin6_addr = in6addr_loopback
            result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, 150) == 1 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }
}

// MARK: - Start and stop

enum RadarProcessControl {
    /// Runs the job again, detached from Browsa, its output in ~/Library/Logs/Browsa/Radar.
    static func start(_ launch: RadarScanner.Launch, port: Int) -> Bool {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Browsa/Radar")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let log = logs.appendingPathComponent("\(port).log").path

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        posix_spawn_file_actions_addchdir(&actions, launch.directory)

        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        // Its own session, so it outlives Browsa and Stop can signal its whole group.
        // Default signal handling too: an app can leave SIGINT ignored, and children inherit that.
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attrs, &defaults)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attrs, &none)

        let argv = [launch.executable] + launch.arguments
        let env = launch.environment.map { "\($0.key)=\($0.value)" }
        var cArgs = argv.map { strdup($0) } + [nil]
        var cEnv = env.map { strdup($0) } + [nil]
        defer { (cArgs + cEnv).forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, launch.executable, &actions, &attrs, &cArgs, &cEnv) == 0
    }

    /// What Ctrl-C in its terminal would do: SIGINT to the job's group, or SIGTERM to the job
    /// when it shares a group with whatever started it.
    /// If it's still there a few seconds later, SIGTERM.
    static func stop(pid: pid_t?, launch: RadarScanner.Launch?) {
        if let group = launch?.processGroup, group > 1, group != getpgrp() {
            kill(-group, SIGINT)
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if kill(-group, 0) == 0 { kill(-group, SIGTERM) } }
        } else if let leader = launch?.leader ?? pid, leader > 1, leader != getpid() {
            kill(leader, SIGTERM)
        }
    }
}

import Foundation
import AppKit
import Darwin

/// Localhost-only static file server. Lets the user expose any number of
/// folders by name, so they can read them in a browser and use the SpeakIt
/// extension's right-click → "Speak with SpeakIt" without hitting Chrome's
/// `file://` prompts.
///
/// Implementation: maintain a private serve-root directory containing one
/// symlink per share, then run `python3 -m http.server`-equivalent against
/// that root. Adding/removing shares rewrites the symlinks live.
@MainActor
final class LocalFileServer: ObservableObject {
    static let shared = LocalFileServer()

    struct Share: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String   // URL slug
        var path: String   // absolute filesystem path
    }

    enum BindMode: String, CaseIterable, Identifiable {
        case localhost  // 127.0.0.1
        case tailnet    // bind only to the Tailscale interface (100.x.x.x)
        case lan        // 0.0.0.0 — anyone on Wi-Fi

        var id: String { rawValue }
        var label: String {
            switch self {
            case .localhost: return "This Mac only"
            case .tailnet: return "Tailnet"
            case .lan: return "Wi-Fi LAN"
            }
        }
    }

    @Published private(set) var shares: [Share] = []
    @Published private(set) var isRunning: Bool = false
    @Published var bindMode: BindMode {
        didSet {
            UserDefaults.standard.set(bindMode.rawValue, forKey: Self.bindModeKey)
            if bindMode != .tailnet, tailscaleHTTPS {
                // HTTPS only makes sense with tailnet — drop it on mode change.
                tailscaleHTTPS = false
                return
            }
            if isRunning { restart() }
        }
    }
    @Published var tailscaleHTTPS: Bool {
        didSet {
            UserDefaults.standard.set(tailscaleHTTPS, forKey: Self.tsHTTPSKey)
            if isRunning { restart() }
        }
    }
    @Published var lastTailscaleError: String?
    @Published private(set) var magicDNSName: String?

    let port: Int = 8765

    private static let sharesKey = "SpeakIt.localServer.shares"
    private static let runningKey = "SpeakIt.localServer.running"
    private static let bindModeKey = "SpeakIt.localServer.bindMode"
    private static let tsHTTPSKey = "SpeakIt.localServer.tailscaleHTTPS"

    private var process: Process?
    private let rootURL: URL

    private init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        rootURL = support.appendingPathComponent("SpeakIt/serve-root", isDirectory: true)
        let raw = UserDefaults.standard.string(forKey: Self.bindModeKey) ?? ""
        bindMode = BindMode(rawValue: raw) ?? .localhost
        tailscaleHTTPS = UserDefaults.standard.bool(forKey: Self.tsHTTPSKey)
        loadShares()
        refreshMagicDNS()
        if UserDefaults.standard.bool(forKey: Self.runningKey) { start() }
    }

    func refreshMagicDNS() {
        let cli = TailscaleHelper.binaryPath()
        guard cli != nil else { magicDNSName = nil; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let dns = TailscaleHelper.magicDNSName()
            DispatchQueue.main.async { self.magicDNSName = dns }
        }
    }

    func restart() {
        guard isRunning else { return }
        stop()
        // Brief delay so the listening socket is released before we re-bind.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.start()
        }
    }

    /// All IPv4 interface addresses keyed by interface name (e.g. "en0",
    /// "utun4"). Skips loopback and down interfaces.
    private func interfaceAddresses() -> [(name: String, ip: String)] {
        var out: [(String, String)] = []
        var ifaddrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrs) == 0, let first = ifaddrs else { return out }
        defer { freeifaddrs(ifaddrs) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  let sa = cur.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                           &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                out.append((String(cString: cur.pointee.ifa_name), String(cString: host)))
            }
        }
        return out
    }

    /// Tailscale assigns each device an IPv4 in 100.64.0.0/10 (CGNAT) on a
    /// utun* virtual interface. Detecting it costs us nothing — no CLI calls.
    var tailscaleAddress: String? {
        for (name, ip) in interfaceAddresses() where name.hasPrefix("utun") {
            if ip.hasPrefix("100.") {
                let octets = ip.split(separator: ".").compactMap { Int($0) }
                if octets.count == 4, (64...127).contains(octets[1]) {
                    return ip
                }
            }
        }
        return nil
    }

    /// Best-effort primary Wi-Fi/Ethernet IPv4 (e.g. "192.168.1.42").
    var lanAddress: String? {
        interfaceAddresses().first(where: { $0.name.hasPrefix("en") })?.ip
    }

    var primaryURLString: String? {
        switch bindMode {
        case .localhost:
            return "http://localhost:\(port)/"
        case .tailnet:
            if tailscaleHTTPS, let dns = magicDNSName { return "https://\(dns)/" }
            if let dns = magicDNSName { return "http://\(dns):\(port)/" }
            return tailscaleAddress.map { "http://\($0):\(port)/" }
        case .lan:
            return lanAddress.map { "http://\($0):\(port)/" }
        }
    }

    var rootURLString: String { "http://localhost:\(port)/" }

    func logFileURL() -> URL {
        let logs = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs", isDirectory: true)
        return logs.appendingPathComponent("SpeakIt-server.log")
    }

    func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([logFileURL()])
    }

    // MARK: Shares

    func addShare(_ url: URL) {
        let base = url.lastPathComponent.isEmpty ? "share" : url.lastPathComponent
        let slug = uniqueSlug(base)
        shares.append(Share(id: UUID(), name: slug, path: url.path))
        persist()
        if isRunning { refreshSymlinks() }
    }

    func removeShare(_ id: UUID) {
        shares.removeAll { $0.id == id }
        persist()
        if isRunning { refreshSymlinks() }
    }

    // MARK: Lifecycle

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard process == nil else { return }
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        refreshSymlinks()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let bindHost: String
        switch bindMode {
        case .localhost:
            bindHost = "127.0.0.1"
        case .tailnet:
            // With HTTPS-via-tailscale-serve we bind only to localhost; the
            // tailscaled daemon proxies inbound :443 → 127.0.0.1:port.
            bindHost = tailscaleHTTPS ? "127.0.0.1" : (tailscaleAddress ?? "127.0.0.1")
        case .lan:
            bindHost = "0.0.0.0"
        }
        proc.arguments = [
            "python3", "-u", "-c",
            """
            import sys, functools, urllib.parse, html, json
            from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler

            ROOT = sys.argv[1]

            MD_TEMPLATE = '''<!doctype html>
            <html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <title>__TITLE__</title>
            <style>
              :root { color-scheme: light dark; }
              body { font: 17px/1.6 -apple-system,system-ui,sans-serif; max-width: 720px; margin: 0 auto 60px; padding: 0 18px; }
              pre, code { font-family: ui-monospace,SFMono-Regular,Menlo,monospace; }
              pre { background: rgba(127,127,127,.12); padding: 12px; border-radius: 8px; overflow-x: auto; }
              code { background: rgba(127,127,127,.12); padding: 1px 4px; border-radius: 4px; }
              pre code { background: transparent; padding: 0; }
              h1,h2,h3 { line-height: 1.25; }
              h1 { font-size: 1.7em; } h2 { font-size: 1.35em; } h3 { font-size: 1.15em; }
              a { color: #0a58ff; }
              img { max-width: 100%; height: auto; }
              blockquote { border-left: 3px solid rgba(127,127,127,.4); margin: 0; padding: 4px 14px; color: #777; }
              table { border-collapse: collapse; }
              th, td { border: 1px solid rgba(127,127,127,.3); padding: 6px 10px; }

              .toolbar {
                position: sticky; top: 0; z-index: 10;
                display: flex; align-items: center; gap: 8px;
                padding: 10px 12px;
                background: color-mix(in srgb, Canvas 92%, transparent);
                backdrop-filter: saturate(160%) blur(10px);
                -webkit-backdrop-filter: saturate(160%) blur(10px);
                border-bottom: 1px solid rgba(127,127,127,.18);
                margin: 0 -18px 18px;
                padding-inline: 18px;
              }
              .toolbar button {
                appearance: none; border: 0;
                background: rgba(127,127,127,.18);
                color: inherit;
                font: inherit; font-size: 14px;
                padding: 8px 14px; border-radius: 999px;
                min-height: 38px; cursor: pointer;
                display: inline-flex; align-items: center; gap: 6px;
              }
              .toolbar button:active { transform: scale(.97); }
              .toolbar button.primary { background: #0a58ff; color: white; }
              .toolbar .spacer { flex: 1; }
              .toolbar .rate { display: inline-flex; align-items: center; gap: 6px; font-size: 13px; color: #888; }
              .toolbar select { font: inherit; font-size: 13px; padding: 4px 6px; border-radius: 6px; }
              .toolbar a { font-size: 12px; color: #888; text-decoration: none; }
              .toolbar .iconBtn {
                display: inline-flex; align-items: center; justify-content: center;
                min-width: 38px; min-height: 38px; padding: 0 10px;
                background: rgba(127,127,127,.18);
                border-radius: 999px; font-size: 17px; color: inherit;
              }
              .subbar {
                display: flex; align-items: center; gap: 10px;
                padding: 4px 0 14px; font-size: 12px; color: #888;
                flex-wrap: wrap;
              }
              .crumbs a { color: #888; text-decoration: none; }
              .crumbs a:hover { text-decoration: underline; }
              .crumbs .sep { opacity: .5; margin: 0 4px; }
              .subbar .srclink { margin-left: auto; }

              article p, article li, article h1, article h2, article h3,
              article h4, article h5, article h6, article blockquote {
                cursor: pointer;
                -webkit-tap-highlight-color: rgba(10,88,255,.18);
              }
              ::selection { background: rgba(10,88,255,.35); }
            </style>
            </head><body>
            <div class="toolbar">
              <button id="navBack" title="Back">←</button>
              <a class="iconBtn" href="/" title="Home">🏠</a>
              <a class="iconBtn" href="__PARENT__" title="Parent folder">↑</a>
              <span class="spacer"></span>
              <button id="selectAll" class="primary">Speak</button>
              <button id="clearSel" title="Stop / clear selection">✕</button>
            </div>
            <div class="subbar">
              <span class="crumbs">__CRUMBS__</span>
              <a href="?raw=1" class="srclink">view source</a>
            </div>
            <article id="md"></article>
            <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
            <script>
              const src = __SRC_JSON__;
              const article = document.getElementById('md');
              article.innerHTML = marked.parse(src, { gfm: true, breaks: false });

              // ----- Speak hook -----
              // iOS: programmatically *select* text → iOS shows its callout
              // bar (Copy / Speak / Translate / …). The user taps "Speak" and
              // the system uses the high-quality voices they've installed
              // (Settings → Accessibility → Spoken Content).
              // Desktop: hand the text to the native SpeakIt app via the
              // `speakit://` URL scheme — TTSEngine speaks it directly.
              const selectAllBtn = document.getElementById('selectAll');
              const clearBtn = document.getElementById('clearSel');
              const navBack = document.getElementById('navBack');
              const IS_IOS = /iPad|iPhone|iPod/.test(navigator.userAgent)
                          || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);

              navBack.addEventListener('click', () => {
                if (history.length > 1) history.back();
                else location.href = '/';
              });
              const SELECTOR = 'p, li, h1, h2, h3, h4, h5, h6, blockquote';

              function selectRange(node) {
                const sel = window.getSelection();
                sel.removeAllRanges();
                const r = document.createRange();
                r.selectNodeContents(node);
                sel.addRange(r);
              }

              function speakItDesktop(text) {
                const t = (text || '').trim();
                if (!t) return;
                location.href = 'speakit://speak?text=' + encodeURIComponent(t);
              }

              selectAllBtn.addEventListener('click', () => {
                if (IS_IOS) {
                  selectRange(article);
                  // iOS sometimes only shows the callout after a tap on the
                  // selection — scroll the start into view so the bar is visible.
                  article.scrollIntoView({ behavior: 'smooth', block: 'start' });
                } else {
                  speakItDesktop(article.innerText);
                }
              });

              clearBtn.addEventListener('click', () => {
                if (IS_IOS) {
                  window.getSelection().removeAllRanges();
                } else {
                  location.href = 'speakit://stop';
                }
              });

              // iOS only: tap a paragraph / heading / list-item to select it,
              // then tap "Speak" in iOS's native callout. On desktop we don't
              // intercept clicks — the player's transcript panel handles
              // jump-to-section so the UX is the same across all sources.
              if (IS_IOS) {
                article.addEventListener('click', (e) => {
                  if (e.target.tagName === 'A') return;
                  let t = e.target;
                  while (t && t !== article && !t.matches(SELECTOR)) t = t.parentElement;
                  if (!t || t === article) return;
                  selectRange(t);
                });
              }
            </script>
            </body></html>
            '''

            class Handler(SimpleHTTPRequestHandler):
                extensions_map = {
                    **SimpleHTTPRequestHandler.extensions_map,
                    '.md': 'text/plain; charset=utf-8',
                    '.txt': 'text/plain; charset=utf-8',
                    '.log': 'text/plain; charset=utf-8',
                    '.yaml': 'text/plain; charset=utf-8',
                    '.yml': 'text/plain; charset=utf-8',
                    '.json': 'application/json; charset=utf-8',
                    '': 'text/plain; charset=utf-8',
                }

                def log_message(self, fmt, *args):
                    sys.stderr.write("[%s] %s\\n" % (self.log_date_time_string(), fmt % args))

                def do_GET(self):
                    parsed = urllib.parse.urlparse(self.path)
                    qs = urllib.parse.parse_qs(parsed.query)
                    is_md = parsed.path.lower().endswith('.md')
                    raw = qs.get('raw', ['0'])[0] == '1'
                    if is_md and not raw:
                        return self._render_markdown(parsed.path)
                    return super().do_GET()

                def list_directory(self, path):
                    # Reuse python's default listing, but wrap with our nav header.
                    import io, os, posixpath, urllib.parse
                    try:
                        names = sorted(os.listdir(path), key=lambda n: n.lower())
                    except OSError:
                        self.send_error(404, "No permission to list directory")
                        return None
                    names = [n for n in names if not n.startswith('.')]

                    url_path = self.path.split('?', 1)[0]
                    if not url_path.endswith('/'): url_path += '/'
                    parts = [p for p in url_path.split('/') if p]
                    crumbs = ['<a href="/">home</a>']
                    accum = ''
                    for i, p in enumerate(parts):
                        accum += '/' + p
                        if i == len(parts) - 1:
                            crumbs.append('<span>' + html.escape(p) + '</span>')
                        else:
                            crumbs.append('<a href="' + html.escape(accum) + '/">' + html.escape(p) + '</a>')
                    crumbs_html = '<span class="sep">/</span>'.join(crumbs) if parts else '<span>home</span>'

                    parent = '/' + '/'.join(parts[:-1])
                    if not parent.endswith('/'): parent += '/'

                    rows = []
                    for name in names:
                        full = os.path.join(path, name)
                        display = name + ('/' if os.path.isdir(full) else '')
                        link = urllib.parse.quote(name) + ('/' if os.path.isdir(full) else '')
                        icon = '📁' if os.path.isdir(full) else ('📝' if name.lower().endswith('.md') else '📄')
                        rows.append('<li><a href="' + html.escape(link) + '"><span class="ico">' + icon + '</span>' + html.escape(display) + '</a></li>')

                    css = '''
                      body { font: 17px/1.6 -apple-system,system-ui,sans-serif; max-width: 720px; margin: 0 auto 60px; padding: 0 18px; }
                      .toolbar { position: sticky; top: 0; z-index: 10;
                        display: flex; align-items: center; gap: 8px;
                        padding: 10px 18px; margin: 0 -18px 0;
                        background: color-mix(in srgb, Canvas 92%, transparent);
                        backdrop-filter: saturate(160%) blur(10px);
                        -webkit-backdrop-filter: saturate(160%) blur(10px);
                        border-bottom: 1px solid rgba(127,127,127,.18); }
                      .toolbar button, .toolbar .iconBtn {
                        appearance: none; border: 0; background: rgba(127,127,127,.18);
                        color: inherit; font: inherit; font-size: 14px;
                        padding: 8px 14px; border-radius: 999px;
                        min-height: 38px; cursor: pointer;
                        display: inline-flex; align-items: center; justify-content: center;
                        min-width: 38px; text-decoration: none; }
                      .toolbar .spacer { flex: 1; }
                      .subbar { padding: 6px 0 14px; font-size: 12px; color: #888;
                        display:flex; align-items:center; gap:8px; flex-wrap:wrap; }
                      .crumbs a { color: #888; text-decoration: none; }
                      .crumbs .sep { opacity: .5; margin: 0 4px; }
                      ul { list-style: none; padding: 0; margin: 8px 0 0; }
                      li a { display: flex; gap: 10px; align-items: center;
                        padding: 14px 12px; border-radius: 10px;
                        text-decoration: none; color: inherit;
                        border: 1px solid transparent;
                        -webkit-tap-highlight-color: rgba(10,88,255,.18); }
                      li a:hover { background: rgba(127,127,127,.08); }
                      li a:active { background: rgba(10,88,255,.12); }
                      .ico { font-size: 18px; width: 22px; text-align: center; }
                    '''

                    page = ('<!doctype html><html><head>'
                            '<meta charset="utf-8">'
                            '<meta name="viewport" content="width=device-width,initial-scale=1">'
                            '<title>' + html.escape(url_path) + '</title>'
                            '<style>:root{color-scheme:light dark;}' + css + '</style>'
                            '</head><body>'
                            '<div class="toolbar">'
                            '<button onclick="if(history.length>1)history.back();else location.href=\\'/\\'">←</button>'
                            '<a class="iconBtn" href="/">🏠</a>'
                            '<a class="iconBtn" href="' + html.escape(parent) + '">↑</a>'
                            '<span class="spacer"></span>'
                            '</div>'
                            '<div class="subbar"><span class="crumbs">' + crumbs_html + '</span></div>'
                            '<ul>' + ''.join(rows) + '</ul>'
                            '</body></html>')
                    data = page.encode('utf-8')
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/html; charset=utf-8')
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    return io.BytesIO(data)

                def _render_markdown(self, url_path):
                    fs_path = self.translate_path(url_path)
                    try:
                        with open(fs_path, 'r', encoding='utf-8', errors='replace') as f:
                            src = f.read()
                    except FileNotFoundError:
                        self.send_error(404); return
                    except Exception as e:
                        self.send_error(500, str(e)); return
                    title = url_path.rsplit('/', 1)[-1] or 'Markdown'
                    parent = url_path.rsplit('/', 1)[0] or '/'
                    if not parent.endswith('/'):
                        parent += '/'

                    # Breadcrumb trail: home / a / b / file.md
                    parts = [p for p in url_path.split('/') if p]
                    crumbs = ['<a href="/">home</a>']
                    accum = ''
                    for i, p in enumerate(parts):
                        accum += '/' + p
                        if i == len(parts) - 1:
                            crumbs.append('<span>' + html.escape(p) + '</span>')
                        else:
                            crumbs.append('<a href="' + html.escape(accum) + '/">' + html.escape(p) + '</a>')
                    crumbs_html = '<span class="sep">/</span>'.join(crumbs)

                    body = (MD_TEMPLATE
                            .replace('__TITLE__', html.escape(title))
                            .replace('__PARENT__', html.escape(parent))
                            .replace('__CRUMBS__', crumbs_html)
                            .replace('__SRC_JSON__', json.dumps(src)))
                    data = body.encode('utf-8')
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/html; charset=utf-8')
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)

            handler = functools.partial(Handler, directory=ROOT)
            ThreadingHTTPServer.allow_reuse_address = True
            with ThreadingHTTPServer(('\(bindHost)', \(port)), handler) as httpd:
                sys.stderr.write("SpeakIt server on http://\(bindHost):\(port) (root=%s)\\n" % ROOT)
                httpd.serve_forever()
            """,
            rootURL.path
        ]
        proc.currentDirectoryURL = rootURL

        // Capture stderr to a log so crashes are diagnosable.
        let logURL = logFileURL()
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            try? handle.seekToEnd()
            proc.standardOutput = handle
            proc.standardError = handle
        } else {
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
        }

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.process = nil
                self?.isRunning = false
            }
        }

        do {
            try proc.run()
            process = proc
            isRunning = true
            UserDefaults.standard.set(true, forKey: Self.runningKey)
            if bindMode == .tailnet, tailscaleHTTPS {
                if let err = TailscaleHelper.enableServeHTTPS(targetPort: port) {
                    lastTailscaleError = err
                } else {
                    lastTailscaleError = nil
                }
            } else {
                TailscaleHelper.disableServeHTTPS()
                lastTailscaleError = nil
            }
            refreshMagicDNS()
        } catch {
            NSLog("[SpeakIt] local server failed to start: \(error)")
        }
    }

    func stop() {
        UserDefaults.standard.set(false, forKey: Self.runningKey)
        TailscaleHelper.disableServeHTTPS()
        process?.terminate()
        process = nil
        isRunning = false
    }

    func openInBrowser() {
        if let url = URL(string: rootURLString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Folder picker

    func pickAndAddShare() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose a folder to serve at http://localhost:\(port)"
        panel.prompt = "Add"
        if panel.runModal() == .OK {
            for url in panel.urls { addShare(url) }
        }
    }

    // MARK: Internals

    private func uniqueSlug(_ base: String) -> String {
        let normalized = slugify(base)
        var candidate = normalized
        var n = 2
        while shares.contains(where: { $0.name == candidate }) {
            candidate = "\(normalized)-\(n)"
            n += 1
        }
        return candidate
    }

    private func slugify(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let dashed = s.lowercased().replacingOccurrences(of: " ", with: "-")
        let cleaned = String(dashed.unicodeScalars.filter { allowed.contains($0) })
        return cleaned.isEmpty ? "share" : cleaned
    }

    private func refreshSymlinks() {
        let fm = FileManager.default
        try? fm.createDirectory(at: rootURL, withIntermediateDirectories: true)

        // Wipe only the *contents* of rootURL, never the directory itself —
        // otherwise the python child's cwd/dir handle goes stale.
        if let contents = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) {
            for url in contents { try? fm.removeItem(at: url) }
        }

        for s in shares {
            let dest = rootURL.appendingPathComponent(s.name)
            try? fm.createSymbolicLink(
                at: dest,
                withDestinationURL: URL(fileURLWithPath: s.path)
            )
        }
        // Don't write index.html — python's list_directory renders the root
        // with the same nav header/breadcrumbs as every subfolder.
    }

    private func loadShares() {
        guard let data = UserDefaults.standard.data(forKey: Self.sharesKey),
              let decoded = try? JSONDecoder().decode([Share].self, from: data) else { return }
        shares = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(shares) {
            UserDefaults.standard.set(data, forKey: Self.sharesKey)
        }
    }
}

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
            import sys, os, functools, urllib.parse, urllib.request, urllib.error, html, json
            import subprocess, tempfile, threading, time, re
            import uuid as _uuid
            from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler

            ROOT = sys.argv[1]

            _JOBS = {}
            _JOBS_LOCK = threading.Lock()
            _MAX_TEXT_CHARS = 200000
            _CHUNK_TARGET_CHARS = 600
            _MAX_WORKERS = 4

            def _split_for_tts(text):
                text = text.replace('\\r\\n', '\\n').replace('\\r', '\\n').strip()
                if not text: return []
                # First pass: split on blank lines (paragraphs).
                paras = [p.strip() for p in re.split(r'\\n\\s*\\n', text) if p.strip()]
                # Second pass: any paragraph longer than target -> split on sentence boundaries.
                out = []
                for p in paras:
                    if len(p) <= _CHUNK_TARGET_CHARS:
                        out.append(p)
                        continue
                    sents = re.split(r'(?<=[.!?\\u2026])\\s+', p)
                    buf = ''
                    for s in sents:
                        if not buf:
                            buf = s
                        elif len(buf) + 1 + len(s) <= _CHUNK_TARGET_CHARS:
                            buf += ' ' + s
                        else:
                            out.append(buf)
                            buf = s
                    if buf:
                        out.append(buf)
                # Third pass: hard-cut any still-too-long chunk.
                final = []
                for c in out:
                    if len(c) <= _CHUNK_TARGET_CHARS * 2:
                        final.append(c)
                    else:
                        for i in range(0, len(c), _CHUNK_TARGET_CHARS):
                            final.append(c[i:i + _CHUNK_TARGET_CHARS])
                return final

            def _tts_render_chunk(text, voice, rate, bin_path):
                tmp = tempfile.NamedTemporaryFile(prefix='speakit-c-', suffix='.mp3', delete=False)
                tmp.close()
                try:
                    proc = subprocess.run(
                        [bin_path, '-v', voice, '-t', text,
                         '--rate=' + rate, '--write-media', tmp.name],
                        capture_output=True, timeout=180,
                    )
                    if proc.returncode != 0:
                        err = (proc.stderr or b'').decode('utf-8', errors='replace')[:200]
                        return None, 'edge-tts: ' + err
                    with open(tmp.name, 'rb') as f:
                        return f.read(), None
                except subprocess.TimeoutExpired:
                    return None, 'chunk timed out'
                except Exception as e:
                    return None, str(e)
                finally:
                    try: os.unlink(tmp.name)
                    except Exception: pass

            def _tts_run_job(job_id):
                with _JOBS_LOCK:
                    job = _JOBS.get(job_id)
                if not job: return
                texts = job['texts']
                voice = job['voice']
                rate = job['rate']
                bin_path = job['bin_path']
                results = [None] * len(texts)
                lock = threading.Lock()
                pending = [0]
                pending[0] = len(texts)

                def worker(i):
                    if job['cancelled']: return
                    data, err = _tts_render_chunk(texts[i], voice, rate, bin_path)
                    with lock:
                        results[i] = data
                        if err and not job['err']:
                            job['err'] = err
                        job['done'] += 1

                threads = []
                from queue import Queue
                q = Queue()
                for i in range(len(texts)): q.put(i)

                def runner():
                    while not q.empty() and not job['cancelled']:
                        try: i = q.get_nowait()
                        except Exception: break
                        worker(i)

                for _ in range(min(_MAX_WORKERS, len(texts))):
                    t = threading.Thread(target=runner, daemon=True)
                    t.start()
                    threads.append(t)
                for t in threads: t.join()

                if job['cancelled']:
                    job['finished'] = True
                    return
                # Concat MP3 frames bytewise. edge-tts emits standalone MP3 frames so simple concat works.
                buf = b''.join(b for b in results if b)
                if not buf and not job['err']:
                    job['err'] = 'no audio produced'
                job['blob'] = buf
                job['finished'] = True

            MD_EXTS = ('.md', '.markdown', '.mdx', '.txt')

            MERMAID_PREFIX_RE = r"^\\s*(graph|flowchart|sequenceDiagram|classDiagram|stateDiagram(-v2)?|erDiagram|journey|gantt|pie|mindmap|timeline|gitGraph|requirementDiagram|C4Context|quadrantChart|xychart-beta)\\b"

            PALETTE_CSS = '''
              ._pal-backdrop { position: fixed; inset: 0; background: rgba(0,0,0,.35); z-index: 9998; }
              ._pal { position: fixed; top: 10vh; left: 50%; transform: translateX(-50%);
                width: min(640px, 92vw); max-height: 80vh; z-index: 9999;
                background: Canvas; color: CanvasText;
                border: 1px solid rgba(127,127,127,.3); border-radius: 12px;
                box-shadow: 0 24px 64px rgba(0,0,0,.35); overflow: hidden;
                display: flex; flex-direction: column; }
              ._pal-tabs { display: flex; gap: 6px; padding: 8px 8px 0; }
              ._pal-tab { appearance: none; border: 0; background: rgba(127,127,127,.12);
                color: inherit; font: inherit; font-size: 13px;
                padding: 6px 12px; border-radius: 999px; cursor: pointer; }
              ._pal-tab._active { background: #0a58ff; color: white; }
              ._pal-input { width: 100%; box-sizing: border-box;
                font: inherit; font-size: 16px;
                padding: 12px 14px; margin: 8px; border-radius: 8px;
                border: 1px solid rgba(127,127,127,.3);
                background: rgba(127,127,127,.06); color: inherit; }
              ._pal-input:focus { outline: 2px solid #0a58ff; }
              ._pal-results { overflow-y: auto; padding: 4px 8px 12px; }
              ._pal-row { display: block; padding: 10px 12px; border-radius: 8px;
                text-decoration: none; color: inherit; }
              ._pal-row:hover, ._pal-row._sel { background: rgba(10,88,255,.12); }
              ._pal-row .pp { font-size: 12px; color: #888; }
              ._pal-row .ps { font-size: 13px; margin-top: 2px; }
              ._pal-row .ps mark { background: rgba(255,220,0,.5); color: inherit; padding: 0 1px; }
              ._pal-empty { padding: 14px; color: #888; font-size: 13px; text-align: center; }
              ._pal-answer { padding: 12px 14px; font-size: 15px; line-height: 1.55;
                white-space: pre-wrap; }
              ._pal-cites { padding: 0 14px 12px; font-size: 12px; color: #888;
                display: flex; flex-wrap: wrap; gap: 6px; }
              ._pal-cites a { background: rgba(127,127,127,.15); padding: 3px 8px;
                border-radius: 999px; text-decoration: none; color: inherit; }
              ._search-fab { position: fixed; right: 18px; bottom: 18px; z-index: 50;
                width: 48px; height: 48px; border-radius: 999px;
                background: #0a58ff; color: white; border: 0; cursor: pointer;
                font-size: 20px; box-shadow: 0 6px 20px rgba(10,88,255,.4); }
              .mermaid { background: rgba(127,127,127,.06); padding: 12px;
                border-radius: 8px; text-align: center; overflow-x: auto; }
              .mermaid svg { max-width: 100%; height: auto; }
              .lucide { width: 18px; height: 18px; stroke-width: 1.75;
                vertical-align: -3px; flex-shrink: 0; }
              .toolbar .lucide { width: 18px; height: 18px; }
              ._search-fab .lucide { width: 22px; height: 22px; stroke: white; }
              li .ico .lucide { width: 18px; height: 18px; opacity: .75; }
              ._pal-tab .lucide { width: 14px; height: 14px; margin-right: 4px;
                vertical-align: -2px; }
            '''

            PALETTE_JS = r'''
              (function(){
                const AI_ENABLED = window.__SPEAKIT_AI__ === true;
                let palette = null;
                let mode = 'search';
                let debounce = null;
                let sel = 0;
                let rows = [];

                function highlight(s, q) {
                  if (!q) return escapeHtml(s);
                  const tokens = q.split(/\\s+/).filter(t => t.length > 0);
                  let out = escapeHtml(s);
                  for (const t of tokens) {
                    const re = new RegExp('('+ t.replace(/[.*+?^${}()|[\\]\\\\]/g,'\\\\$&') +')', 'gi');
                    out = out.replace(re, '<mark>$1</mark>');
                  }
                  return out;
                }
                function escapeHtml(s) {
                  return String(s).replace(/[&<>\"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;',\"'\":'&#39;'}[c]));
                }

                function ensurePalette() {
                  if (palette) return palette;
                  const w = document.createElement('div');
                  w.id = '_pal-wrap';
                  w.innerHTML =
                    '<div class=\"_pal-backdrop\"></div>' +
                    '<div class=\"_pal\" role=\"dialog\" aria-modal=\"true\">' +
                      '<div class=\"_pal-tabs\">' +
                        '<button class=\"_pal-tab _active\" data-mode=\"search\">Search</button>' +
                        (AI_ENABLED ? '<button class=\"_pal-tab\" data-mode=\"ask\">Ask AI</button>' : '') +
                      '</div>' +
                      '<input class=\"_pal-input\" placeholder=\"Type to search\\u2026\" autocomplete=\"off\" />' +
                      '<div class=\"_pal-results\"></div>' +
                    '</div>';
                  document.body.appendChild(w);
                  palette = w;
                  w.querySelector('._pal-backdrop').addEventListener('click', closePalette);
                  w.querySelectorAll('._pal-tab').forEach(b =>
                    b.addEventListener('click', () => setMode(b.dataset.mode)));
                  const input = w.querySelector('._pal-input');
                  input.addEventListener('input', onInput);
                  input.addEventListener('keydown', onKey);
                  return w;
                }
                function setMode(m) {
                  mode = m;
                  if (!palette) return;
                  palette.querySelectorAll('._pal-tab').forEach(b =>
                    b.classList.toggle('_active', b.dataset.mode === m));
                  const input = palette.querySelector('._pal-input');
                  input.placeholder = (m === 'ask') ? 'Ask a question about your notes\\u2026' : 'Type to search\\u2026';
                  palette.querySelector('._pal-results').innerHTML = '';
                  input.focus();
                }
                function openPalette() {
                  ensurePalette();
                  palette.style.display = 'block';
                  const input = palette.querySelector('._pal-input');
                  input.value = '';
                  palette.querySelector('._pal-results').innerHTML = '';
                  setTimeout(() => input.focus(), 0);
                }
                function closePalette() {
                  if (palette) palette.style.display = 'none';
                }
                function onInput(e) {
                  clearTimeout(debounce);
                  const q = e.target.value.trim();
                  if (mode === 'ask') return;
                  if (!q) { palette.querySelector('._pal-results').innerHTML = ''; return; }
                  debounce = setTimeout(() => doSearch(q), 140);
                }
                function onKey(e) {
                  if (e.key === 'Escape') { closePalette(); return; }
                  if (e.key === 'Enter') {
                    if (mode === 'ask') { e.preventDefault(); doAsk(e.target.value.trim()); return; }
                    const row = rows[sel];
                    if (row) { e.preventDefault(); location.href = row.href; }
                    return;
                  }
                  if (e.key === 'ArrowDown') { e.preventDefault(); moveSel(1); }
                  else if (e.key === 'ArrowUp') { e.preventDefault(); moveSel(-1); }
                  else if (e.key === 'Tab') {
                    if (AI_ENABLED) { e.preventDefault(); setMode(mode === 'search' ? 'ask' : 'search'); }
                  }
                }
                function moveSel(d) {
                  if (!rows.length) return;
                  const els = palette.querySelectorAll('._pal-row');
                  sel = (sel + d + rows.length) % rows.length;
                  els.forEach((el, i) => el.classList.toggle('_sel', i === sel));
                  els[sel].scrollIntoView({ block: 'nearest' });
                }
                async function doSearch(q) {
                  const res = palette.querySelector('._pal-results');
                  res.innerHTML = '<div class=\"_pal-empty\">Searching\\u2026</div>';
                  try {
                    const r = await fetch('/_search?q=' + encodeURIComponent(q));
                    const data = await r.json();
                    rows = data.results || [];
                    sel = 0;
                    if (!rows.length) {
                      const st = data.stats || {};
                      const shares = (st.shares || []).join(', ') || '(none)';
                      res.innerHTML = '<div class=\"_pal-empty\">No matches.<br><br>' +
                        'Searched <b>' + (st.files_seen || 0) + '</b> files across shares: <code>' +
                        escapeHtml(shares) + '</code>.<br>' +
                        'If your file isn\\'t under one of these shares, add its parent folder in the SpeakIt menu.</div>';
                      return;
                    }
                    res.innerHTML = rows.map((row, i) => {
                      const isContent = row.kind === 'content';
                      const href = isContent ? (row.path + '#L' + row.line) : row.path;
                      row.href = href;
                      const path = row.path.replace(/^\\//, '');
                      const tag = row.kind === 'folder' ? 'folder'
                                : row.kind === 'file' ? 'file'
                                : ('line ' + row.line);
                      const snippet = isContent ? highlight(row.snippet, q) : highlight(path, q);
                      return '<a class=\"_pal-row' + (i===0?' _sel':'') + '\" href=\"' + escapeHtml(href) + '\">' +
                        '<div class=\"pp\">' + escapeHtml(path) + ' \\u00b7 ' + tag + '</div>' +
                        '<div class=\"ps\">' + snippet + '</div>' +
                      '</a>';
                    }).join('');
                  } catch (err) {
                    res.innerHTML = '<div class=\"_pal-empty\">Error: ' + escapeHtml(String(err)) + '</div>';
                  }
                }
                async function doAsk(q) {
                  if (!q) return;
                  const res = palette.querySelector('._pal-results');
                  res.innerHTML = '<div class=\"_pal-empty\">Thinking\\u2026</div>';
                  try {
                    const r = await fetch('/_ask', {
                      method: 'POST',
                      headers: {'Content-Type': 'application/json'},
                      body: JSON.stringify({ q: q })
                    });
                    const data = await r.json();
                    if (data.error) {
                      res.innerHTML = '<div class=\"_pal-empty\">' + escapeHtml(data.error) + '</div>';
                      return;
                    }
                    const cites = (data.citations || []).map(p =>
                      '<a href=\"' + escapeHtml(p) + '\">' + escapeHtml(p.replace(/^\\//, '')) + '</a>'
                    ).join('');
                    res.innerHTML =
                      '<div class=\"_pal-answer\">' + escapeHtml(data.answer || '') + '</div>' +
                      (cites ? '<div class=\"_pal-cites\">' + cites + '</div>' : '');
                  } catch (err) {
                    res.innerHTML = '<div class=\"_pal-empty\">Error: ' + escapeHtml(String(err)) + '</div>';
                  }
                }

                // Keyboard: /, Cmd-K, Ctrl-K to open. Esc to close.
                document.addEventListener('keydown', (e) => {
                  if (palette && palette.style.display === 'block') return;
                  const inField = /input|textarea|select/i.test((e.target && e.target.tagName) || '');
                  if (inField) return;
                  if (e.key === '/' || ((e.metaKey || e.ctrlKey) && (e.key === 'k' || e.key === 'K'))) {
                    e.preventDefault();
                    openPalette();
                  }
                });

                // Floating action button — also serves mobile.
                const fab = document.createElement('button');
                fab.className = '_search-fab';
                fab.title = 'Search  (press /)';
                fab.innerHTML = '<i data-lucide=\"search\"></i>';
                fab.addEventListener('click', openPalette);
                document.body.appendChild(fab);
                if (window.lucide && window.lucide.createIcons) {
                  try { lucide.createIcons(); } catch (e) {}
                }

                window.__openSearchPalette = openPalette;
              })();
            '''

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
              .toolbar button, .toolbar .iconBtn {
                appearance: none; border: 0;
                background: rgba(127,127,127,.18);
                color: inherit;
                font: inherit; font-size: 14px;
                width: 38px; height: 38px; padding: 0;
                border-radius: 999px;
                cursor: pointer; text-decoration: none;
                display: inline-flex; align-items: center; justify-content: center;
                gap: 6px; box-sizing: border-box;
              }
              .toolbar button:active, .toolbar .iconBtn:active { transform: scale(.97); }
              .toolbar button.primary {
                background: #0a58ff; color: white;
                width: auto; padding: 0 16px;
              }
              .toolbar .spacer { flex: 1; }
              .toolbar .rate { display: inline-flex; align-items: center; gap: 6px; font-size: 13px; color: #888; }
              .toolbar select { font: inherit; font-size: 13px; padding: 4px 6px; border-radius: 6px; }
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
              @keyframes _spin { to { transform: rotate(360deg); } }
              ._busy { position: relative; }
              ._busy > i, ._busy > svg { display: none; }
              ._ring {
                position: absolute; inset: 0; pointer-events: none;
                display: flex; align-items: center; justify-content: center;
              }
              ._ring svg { width: 38px; height: 38px; transform: rotate(-90deg); }
              ._ring svg circle._track {
                fill: none; stroke: rgba(127,127,127,.35); stroke-width: 3;
              }
              ._ring svg circle._bar {
                fill: none; stroke: #0a58ff; stroke-width: 3; stroke-linecap: round;
                transition: stroke-dashoffset 120ms linear;
              }
              ._indet ._ring svg { animation: _spin 1.1s linear infinite; }
              ._indet ._ring svg circle._bar { stroke-dashoffset: 70 !important; }
              ._pct {
                position: absolute; inset: 0;
                display: flex; align-items: center; justify-content: center;
                font-size: 10px; font-weight: 600; color: inherit;
                font-variant-numeric: tabular-nums;
                pointer-events: none;
              }
              ._indet ._pct { display: none; }
              __PALETTE_CSS__
            </style>
            </head><body>
            <script>window.__SPEAKIT_AI__ = __AI_FLAG__;</script>
            <div class="toolbar">
              <button id="navBack" title="Back"><i data-lucide="arrow-left"></i></button>
              <a class="iconBtn" href="/" title="Home"><i data-lucide="house"></i></a>
              <a class="iconBtn" href="__PARENT__" title="Parent folder"><i data-lucide="arrow-up"></i></a>
              <span class="spacer"></span>
              <button id="selectAll" class="primary"><i data-lucide="volume-2"></i> Speak</button>
              <button id="dlAudio" title="Download as MP3"><i data-lucide="download"></i></button>
              <button id="dlPdf" title="Download as PDF"><i data-lucide="file-down"></i></button>
              <button id="clearSel" title="Stop / clear selection"><i data-lucide="x"></i></button>
            </div>
            <div class="subbar">
              <span class="crumbs">__CRUMBS__</span>
              <a href="?raw=1" class="srclink">view source</a>
            </div>
            <article id="md"></article>
            <script src="https://cdn.jsdelivr.net/npm/marked@15/marked.min.js"></script>
            <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
            <script src="https://cdn.jsdelivr.net/npm/lucide@0.460.0/dist/umd/lucide.min.js"></script>
            <script>
              const src = __SRC_JSON__;
              const article = document.getElementById('md');
              const MERMAID_PREFIX = /^\\s*(graph|flowchart|sequenceDiagram|classDiagram|stateDiagram(-v2)?|erDiagram|journey|gantt|pie|mindmap|timeline|gitGraph|requirementDiagram|C4Context|quadrantChart|xychart-beta)\\b/;
              function escapeHtml(s) {
                return String(s).replace(/[&<>"']/g, c =>
                  ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
              }
              const renderer = new marked.Renderer();
              renderer.code = function(arg, infoString) {
                const isObj = (typeof arg === 'object' && arg !== null);
                const code = isObj ? (arg.text || '') : arg;
                const lang = isObj ? ((arg.lang || '').trim().split(/\\s+/)[0])
                                   : ((infoString || '').trim().split(/\\s+/)[0]);
                if (lang === 'mermaid' || (!lang && MERMAID_PREFIX.test(code))) {
                  return '<div class="mermaid">' + escapeHtml(code) + '</div>';
                }
                return '<pre><code' + (lang ? ' class="language-' + lang + '"' : '') + '>' +
                       escapeHtml(code) + '</code></pre>';
              };
              article.innerHTML = marked.parse(src, { gfm: true, breaks: false, renderer });
              if (window.lucide && window.lucide.createIcons) {
                try { lucide.createIcons(); } catch (e) {}
              }
              if (window.mermaid) {
                try {
                  mermaid.initialize({ startOnLoad: false,
                    theme: matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default' });
                  mermaid.run({ querySelector: '.mermaid' }).catch(() => {});
                } catch (e) { console.warn('mermaid:', e); }
              }
              // Jump to #L<n> if present (from search results).
              if (location.hash.match(/^#L\\d+$/)) {
                const n = parseInt(location.hash.slice(2), 10);
                const blocks = article.querySelectorAll('p, li, h1, h2, h3, h4, h5, h6, blockquote, pre');
                if (blocks[Math.min(n - 1, blocks.length - 1)]) {
                  blocks[Math.min(n - 1, blocks.length - 1)].scrollIntoView({ block: 'center' });
                }
              }

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

              const dlBtn = document.getElementById('dlAudio');
              const pdfBtn = document.getElementById('dlPdf');
              const RING_R = 16;
              const RING_C = 2 * Math.PI * RING_R;
              function ringHTML() {
                return '<span class="_ring"><svg viewBox="0 0 38 38">' +
                  '<circle class="_track" cx="19" cy="19" r="' + RING_R + '"></circle>' +
                  '<circle class="_bar" cx="19" cy="19" r="' + RING_R + '"' +
                  ' stroke-dasharray="' + RING_C.toFixed(2) + '"' +
                  ' stroke-dashoffset="' + RING_C.toFixed(2) + '"></circle>' +
                '</svg></span><span class="_pct">0%</span>';
              }
              function setBtnProgress(btn, pct) {
                const bar = btn.querySelector('._bar');
                const lbl = btn.querySelector('._pct');
                if (!bar || !lbl) return;
                const p = Math.max(0, Math.min(1, pct));
                bar.setAttribute('stroke-dashoffset', (RING_C * (1 - p)).toFixed(2));
                lbl.textContent = Math.round(p * 100) + '%';
              }
              function setProgress(pct) { setBtnProgress(dlBtn, pct); }
              function slugifyTitle() {
                return (document.title || 'speakit')
                  .replace(/\\.[^.]+$/, '')
                  .replace(/[^a-z0-9-_]+/gi, '-')
                  .slice(0, 60) || 'speakit';
              }
              function loadScript(src) {
                return new Promise((resolve, reject) => {
                  const s = document.createElement('script');
                  s.src = src; s.onload = resolve;
                  s.onerror = () => reject(new Error('Failed to load ' + src));
                  document.head.appendChild(s);
                });
              }
              dlBtn.addEventListener('click', async () => {
                if (dlBtn.classList.contains('_busy')) return;
                const text = (article.innerText || '').trim();
                if (!text) return;
                const originalHTML = dlBtn.innerHTML;
                dlBtn.classList.add('_busy', '_indet');
                dlBtn.insertAdjacentHTML('beforeend', ringHTML());
                dlBtn.title = 'Starting\\u2026';
                let es = null;
                let jobId = null;
                try {
                  const slug = slugifyTitle();
                  const start = await fetch('/_tts/start', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({ text: text, filename: slug })
                  });
                  const startData = await start.json().catch(() => ({}));
                  if (!start.ok || !startData.id) {
                    alert('TTS failed: ' + (startData.error || start.status));
                    return;
                  }
                  jobId = startData.id;
                  const total = startData.total || 1;
                  dlBtn.classList.remove('_indet');
                  dlBtn.title = 'Synthesizing 0/' + total;
                  // Stream progress via SSE.
                  const finished = await new Promise((resolve) => {
                    es = new EventSource('/_tts/events?id=' + encodeURIComponent(jobId));
                    es.onmessage = (ev) => {
                      try {
                        const m = JSON.parse(ev.data);
                        if (m.total) setProgress(m.done / m.total);
                        dlBtn.title = 'Synthesizing ' + m.done + '/' + m.total;
                        if (m.finished) { es.close(); resolve(m); }
                        if (m.err && !m.finished) { /* keep polling, may still finish */ }
                      } catch (e) {}
                    };
                    es.onerror = () => { es.close(); resolve({ finished: true, err: 'event stream lost' }); };
                  });
                  if (finished.err && !finished.finished) {
                    alert('TTS error: ' + finished.err); return;
                  }
                  // Fetch the assembled file with download progress.
                  dlBtn.title = 'Downloading\\u2026';
                  setProgress(0.98);
                  const fileResp = await fetch('/_tts/file?id=' + encodeURIComponent(jobId));
                  if (!fileResp.ok) {
                    const e = await fileResp.json().catch(() => ({}));
                    alert('TTS error: ' + (e.error || fileResp.status));
                    return;
                  }
                  const blob = await fileResp.blob();
                  setProgress(1);
                  saveBlob(blob, slug + '.mp3');
                  dlBtn.title = 'Done';
                  await new Promise(res => setTimeout(res, 400));
                } catch (err) {
                  alert('TTS error: ' + err);
                } finally {
                  if (es) try { es.close(); } catch (e) {}
                  dlBtn.classList.remove('_busy', '_indet');
                  dlBtn.innerHTML = originalHTML;
                  dlBtn.title = 'Download as MP3';
                  if (window.lucide) try { lucide.createIcons(); } catch (e) {}
                }
              });
              function saveBlob(blob, name) {
                const url = URL.createObjectURL(blob);
                const a = document.createElement('a');
                a.href = url; a.download = name;
                document.body.appendChild(a); a.click(); a.remove();
                setTimeout(() => URL.revokeObjectURL(url), 60000);
              }

              pdfBtn.addEventListener('click', async () => {
                if (pdfBtn.classList.contains('_busy')) return;
                const originalHTML = pdfBtn.innerHTML;
                pdfBtn.classList.add('_busy', '_indet');
                pdfBtn.insertAdjacentHTML('beforeend', ringHTML());
                pdfBtn.title = 'Preparing PDF\\u2026';
                try {
                  if (!window.html2pdf) {
                    await loadScript('https://cdn.jsdelivr.net/npm/html2pdf.js@0.10.3/dist/html2pdf.bundle.min.js');
                  }
                  // Let mermaid finish rendering before snapshot.
                  if (window.mermaid) {
                    try { await mermaid.run({ querySelector: '.mermaid' }); } catch (e) {}
                  }
                  const slug = slugifyTitle();
                  const wrap = document.createElement('div');
                  wrap.style.cssText = 'padding:24px; background:white; color:black; max-width:720px; margin:0 auto;';
                  const h = document.createElement('h1');
                  h.textContent = document.title || slug;
                  h.style.cssText = 'font: 600 22px/1.3 -apple-system,system-ui,sans-serif; margin: 0 0 18px;';
                  wrap.appendChild(h);
                  const clone = article.cloneNode(true);
                  clone.style.cssText = 'font: 14px/1.55 -apple-system,system-ui,sans-serif; color: black;';
                  clone.querySelectorAll('pre, code').forEach(el => {
                    el.style.background = '#f3f3f3';
                    el.style.color = '#111';
                  });
                  clone.querySelectorAll('a').forEach(a => { a.style.color = '#0a58ff'; });
                  wrap.appendChild(clone);

                  const opts = {
                    margin: [12, 12, 14, 12],
                    filename: slug + '.pdf',
                    image: { type: 'jpeg', quality: 0.95 },
                    html2canvas: { scale: 2, useCORS: true, backgroundColor: '#ffffff', logging: false },
                    jsPDF: { unit: 'mm', format: 'a4', orientation: 'portrait' },
                    pagebreak: { mode: ['avoid-all', 'css', 'legacy'] },
                  };

                  // Drive a fake progress: html2pdf doesn't expose one. Phase 1: rasterizing
                  // (indeterminate). Phase 2: building PDF (we'll tick 0->100 over ~estimated time).
                  pdfBtn.title = 'Rendering\\u2026';
                  const worker = html2pdf().from(wrap).set(opts);
                  await worker.toContainer();
                  pdfBtn.classList.remove('_indet');
                  // Visual progress while html2canvas runs the heavy work.
                  let tick = 0;
                  const fakeTimer = setInterval(() => {
                    tick = Math.min(0.92, tick + 0.03);
                    setBtnProgress(pdfBtn, tick);
                  }, 180);
                  try {
                    await worker.toCanvas();
                    setBtnProgress(pdfBtn, 0.96);
                    await worker.toPdf();
                    setBtnProgress(pdfBtn, 1);
                  } finally {
                    clearInterval(fakeTimer);
                  }
                  await worker.save();
                  pdfBtn.title = 'Done';
                  await new Promise(res => setTimeout(res, 400));
                } catch (err) {
                  alert('PDF error: ' + err);
                } finally {
                  pdfBtn.classList.remove('_busy', '_indet');
                  pdfBtn.innerHTML = originalHTML;
                  pdfBtn.title = 'Download as PDF';
                  if (window.lucide) try { lucide.createIcons(); } catch (e) {}
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
            <script>__PALETTE_JS__</script>
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
                    if parsed.path == '/_search':
                        return self._do_search(qs.get('q', [''])[0])
                    if parsed.path == '/_tts/events':
                        return self._tts_events(qs.get('id', [''])[0])
                    if parsed.path == '/_tts/file':
                        return self._tts_file(qs.get('id', [''])[0])
                    is_md = parsed.path.lower().endswith('.md')
                    raw = qs.get('raw', ['0'])[0] == '1'
                    if is_md and not raw:
                        return self._render_markdown(parsed.path)
                    return super().do_GET()

                def do_POST(self):
                    parsed = urllib.parse.urlparse(self.path)
                    if parsed.path in ('/_ask', '/_tts/start', '/_tts/cancel'):
                        length = int(self.headers.get('Content-Length', '0') or '0')
                        raw = self.rfile.read(length) if length > 0 else b''
                        try:
                            data = json.loads(raw.decode('utf-8', errors='replace') or '{}')
                        except Exception:
                            return self._json({'error': 'bad json'}, status=400)
                        if parsed.path == '/_ask':
                            return self._do_ask(data.get('q', ''))
                        if parsed.path == '/_tts/start':
                            return self._tts_start(data)
                        return self._tts_cancel(data.get('id', ''))
                    self.send_error(405, 'method not allowed')

                def _json(self, obj, status=200):
                    data = json.dumps(obj).encode('utf-8')
                    self.send_response(status)
                    self.send_header('Content-Type', 'application/json; charset=utf-8')
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return None

                def _iter_md_files(self):
                    try:
                        shares = sorted(os.listdir(ROOT))
                    except OSError:
                        return
                    for sh in shares:
                        if sh.startswith('.'): continue
                        base = os.path.join(ROOT, sh)
                        for root, dirs, files in os.walk(base, followlinks=True):
                            dirs[:] = [d for d in dirs if not d.startswith('.')]
                            for fn in files:
                                if fn.startswith('.'): continue
                                if fn.lower().endswith(MD_EXTS):
                                    yield os.path.join(root, fn)

                def _do_search(self, q):
                    q = (q or '').strip()
                    if not q:
                        return self._json({'results': []})
                    needle = q.lower()
                    tokens = [t for t in needle.split() if len(t) >= 2]
                    name_hits = []
                    body_hits = []
                    MAX_RESULTS = 50
                    MAX_FILES = 4000
                    stats = {'shares': [], 'files_seen': 0, 'files_scanned': 0}

                    # First pass: filename/path matches across every share (any extension).
                    def _walk_all():
                        try:
                            shares = sorted(os.listdir(ROOT))
                        except OSError:
                            return
                        for sh in shares:
                            if sh.startswith('.'): continue
                            stats['shares'].append(sh)
                            base = os.path.join(ROOT, sh)
                            for root, dirs, files in os.walk(base, followlinks=True):
                                dirs[:] = [d for d in dirs if not d.startswith('.')]
                                rel_dir = '/' + os.path.relpath(root, ROOT).replace(os.sep, '/')
                                # Also surface matching directories.
                                def _path_match(s):
                                    low = s.lower()
                                    if needle in low: return True
                                    return bool(tokens) and all(t in low for t in tokens)
                                for d in dirs:
                                    rd_full = (rel_dir.rstrip('/') + '/' + d + '/').replace('//','/')
                                    if _path_match(d) or _path_match(rd_full):
                                        yield ('dir', rd_full, None)
                                for fn in files:
                                    if fn.startswith('.'): continue
                                    stats['files_seen'] += 1
                                    full = os.path.join(root, fn)
                                    rel = (rel_dir.rstrip('/') + '/' + fn).replace('//','/')
                                    if _path_match(rel):
                                        yield ('name', rel, full)
                                    elif fn.lower().endswith(MD_EXTS):
                                        yield ('content', rel, full)

                    scanned = 0
                    for kind, rel, full in _walk_all():
                        if kind == 'dir':
                            name_hits.append({'path': rel, 'line': 0, 'snippet': rel, 'kind': 'folder'})
                            continue
                        if kind == 'name':
                            name_hits.append({'path': rel, 'line': 0, 'snippet': rel, 'kind': 'file'})
                            if not full or not full.lower().endswith(MD_EXTS):
                                continue
                            # fall through to also scan content
                        scanned += 1
                        if scanned > MAX_FILES:
                            continue
                        try:
                            with open(full, 'r', encoding='utf-8', errors='replace') as f:
                                for i, line in enumerate(f, 1):
                                    low = line.lower()
                                    if needle in low or (tokens and all(t in low for t in tokens)):
                                        body_hits.append({
                                            'path': rel,
                                            'line': i,
                                            'snippet': line.strip()[:240],
                                            'kind': 'content',
                                        })
                                        if len(body_hits) >= MAX_RESULTS: break
                        except Exception:
                            continue
                        if len(name_hits) + len(body_hits) >= MAX_RESULTS:
                            break

                    stats['files_scanned'] = scanned
                    results = (name_hits + body_hits)[:MAX_RESULTS]
                    return self._json({'results': results, 'stats': stats})

                def _do_ask(self, q):
                    if os.environ.get('SPEAKIT_LLM_ENABLED') != '1':
                        return self._json({'error': 'AI search not enabled. Open SpeakIt menu \\u2192 Reader AI.'}, status=503)
                    q = (q or '').strip()
                    if not q:
                        return self._json({'error': 'empty query'}, status=400)

                    needle = q.lower()
                    tokens = [t for t in needle.split() if len(t) >= 3]
                    picks = []
                    seen = set()
                    MAX_DOCS = 8
                    MAX_CHARS = 3500
                    for fpath in self._iter_md_files():
                        if fpath in seen: continue
                        try:
                            with open(fpath, 'r', encoding='utf-8', errors='replace') as f:
                                txt = f.read()
                        except Exception:
                            continue
                        low = txt.lower()
                        score = 0
                        if needle in low: score += 5
                        for t in tokens:
                            if t in low: score += 1
                        if score <= 0: continue
                        rel = '/' + os.path.relpath(fpath, ROOT).replace(os.sep, '/')
                        picks.append((score, rel, txt[:MAX_CHARS]))
                        seen.add(fpath)
                    picks.sort(key=lambda x: -x[0])
                    picks = picks[:MAX_DOCS]

                    if not picks:
                        return self._json({'answer': 'No matching documents were found for that query.',
                                           'citations': []})

                    sys_prompt = ('You are an assistant answering questions about the user\\'s notes. '
                                  'Use only the provided context. Cite documents by path in square brackets, '
                                  'e.g. [/folder/file.md]. If the answer is not in the context, say so plainly.')
                    user = 'Question: ' + q + '\\n\\nContext:\\n'
                    for _, p, t in picks:
                        user += '\\n--- ' + p + ' ---\\n' + t + '\\n'

                    base = (os.environ.get('SPEAKIT_LLM_URL', '') or '').rstrip('/')
                    model = os.environ.get('SPEAKIT_LLM_MODEL', '') or ''
                    key = os.environ.get('SPEAKIT_LLM_KEY', '') or ''
                    if not base or not model:
                        return self._json({'error': 'LLM base URL or model not configured.'}, status=500)
                    url = base + '/chat/completions'
                    payload = {
                        'model': model,
                        'messages': [
                            {'role': 'system', 'content': sys_prompt},
                            {'role': 'user', 'content': user},
                        ],
                        'stream': False,
                        'temperature': 0.2,
                    }
                    req = urllib.request.Request(
                        url,
                        data=json.dumps(payload).encode('utf-8'),
                        headers={'Content-Type': 'application/json'},
                        method='POST',
                    )
                    if key:
                        req.add_header('Authorization', 'Bearer ' + key)
                    try:
                        with urllib.request.urlopen(req, timeout=90) as resp:
                            raw = resp.read().decode('utf-8', errors='replace')
                    except urllib.error.HTTPError as e:
                        try:
                            body = e.read().decode('utf-8', errors='replace')[:500]
                        except Exception:
                            body = ''
                        return self._json({'error': 'LLM HTTP ' + str(e.code) + ': ' + body}, status=502)
                    except Exception as e:
                        return self._json({'error': 'LLM call failed: ' + str(e)}, status=502)
                    answer = ''
                    try:
                        data = json.loads(raw)
                        answer = data['choices'][0]['message']['content']
                    except Exception:
                        answer = raw[:2000]
                    return self._json({
                        'answer': answer,
                        'citations': [p for _, p, _ in picks],
                    })

                def _tts_start(self, data):
                    text = (data.get('text') or '').strip()
                    if not text:
                        return self._json({'error': 'empty text'}, status=400)
                    if len(text) > _MAX_TEXT_CHARS:
                        text = text[:_MAX_TEXT_CHARS]
                    voice = data.get('voice') or os.environ.get('SPEAKIT_EDGE_TTS_VOICE', '') or 'en-GB-SoniaNeural'
                    rate = data.get('rate') or '+0%'
                    filename = (data.get('filename') or 'speakit').strip() or 'speakit'
                    filename = ''.join(c for c in filename if c.isalnum() or c in '-_') or 'speakit'
                    bin_path = os.environ.get('SPEAKIT_EDGE_TTS_BIN', '')
                    if not bin_path or not os.path.exists(bin_path):
                        return self._json({'error': 'edge-tts not installed on the host.'}, status=503)

                    texts = _split_for_tts(text)
                    if not texts:
                        return self._json({'error': 'no text to synthesize'}, status=400)

                    # Prune jobs older than 1h.
                    now = time.time()
                    with _JOBS_LOCK:
                        stale = [jid for jid, j in _JOBS.items() if now - j.get('started', now) > 3600]
                        for jid in stale: _JOBS.pop(jid, None)

                    job_id = _uuid.uuid4().hex
                    job = {
                        'texts': texts,
                        'voice': voice,
                        'rate': rate,
                        'filename': filename,
                        'bin_path': bin_path,
                        'total': len(texts),
                        'done': 0,
                        'err': None,
                        'finished': False,
                        'cancelled': False,
                        'started': now,
                        'blob': None,
                    }
                    with _JOBS_LOCK:
                        _JOBS[job_id] = job
                    threading.Thread(target=_tts_run_job, args=(job_id,), daemon=True).start()
                    return self._json({'id': job_id, 'total': len(texts), 'filename': filename})

                def _tts_cancel(self, job_id):
                    with _JOBS_LOCK:
                        job = _JOBS.get(job_id)
                    if not job: return self._json({'error': 'not found'}, status=404)
                    job['cancelled'] = True
                    return self._json({'ok': True})

                def _tts_events(self, job_id):
                    with _JOBS_LOCK:
                        job = _JOBS.get(job_id)
                    if not job:
                        return self._json({'error': 'not found'}, status=404)
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/event-stream; charset=utf-8')
                    self.send_header('Cache-Control', 'no-cache')
                    self.send_header('X-Accel-Buffering', 'no')
                    self.end_headers()
                    try:
                        while True:
                            payload = {
                                'done': job['done'],
                                'total': job['total'],
                                'finished': job['finished'],
                                'err': job['err'],
                            }
                            self.wfile.write(('data: ' + json.dumps(payload) + '\\n\\n').encode('utf-8'))
                            try: self.wfile.flush()
                            except Exception: break
                            if job['finished'] or job['cancelled']:
                                break
                            time.sleep(0.25)
                    except Exception:
                        pass
                    return None

                def _tts_file(self, job_id):
                    with _JOBS_LOCK:
                        job = _JOBS.get(job_id)
                    if not job:
                        return self._json({'error': 'not found'}, status=404)
                    if not job['finished']:
                        return self._json({'error': 'not finished'}, status=409)
                    if job['err'] and not job.get('blob'):
                        return self._json({'error': job['err']}, status=502)
                    blob = job.get('blob') or b''
                    self.send_response(200)
                    self.send_header('Content-Type', 'audio/mpeg')
                    self.send_header('Content-Length', str(len(blob)))
                    self.send_header('Content-Disposition',
                                     'attachment; filename="' + job['filename'] + '.mp3"')
                    self.end_headers()
                    # Stream in 64KB chunks.
                    for i in range(0, len(blob), 65536):
                        try:
                            self.wfile.write(blob[i:i + 65536])
                        except Exception:
                            break
                    return None

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
                        if os.path.isdir(full):
                            icon_name = 'folder'
                        elif name.lower().endswith('.md') or name.lower().endswith('.markdown'):
                            icon_name = 'file-text'
                        else:
                            icon_name = 'file'
                        rows.append('<li><a href="' + html.escape(link) + '"><span class="ico"><i data-lucide="' + icon_name + '"></i></span>' + html.escape(display) + '</a></li>')

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
                        width: 38px; height: 38px; padding: 0;
                        border-radius: 999px; cursor: pointer;
                        display: inline-flex; align-items: center; justify-content: center;
                        text-decoration: none; box-sizing: border-box; }
                      .toolbar button:active, .toolbar .iconBtn:active { transform: scale(.97); }
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

                    ai_flag = 'true' if os.environ.get('SPEAKIT_LLM_ENABLED') == '1' else 'false'
                    page = ('<!doctype html><html><head>'
                            '<meta charset="utf-8">'
                            '<meta name="viewport" content="width=device-width,initial-scale=1">'
                            '<title>' + html.escape(url_path) + '</title>'
                            '<style>:root{color-scheme:light dark;}' + css + PALETTE_CSS + '</style>'
                            '</head><body>'
                            '<script>window.__SPEAKIT_AI__ = ' + ai_flag + ';</script>'
                            '<div class="toolbar">'
                            '<button onclick="if(history.length>1)history.back();else location.href=\\'/\\'"><i data-lucide="arrow-left"></i></button>'
                            '<a class="iconBtn" href="/"><i data-lucide="house"></i></a>'
                            '<a class="iconBtn" href="' + html.escape(parent) + '"><i data-lucide="arrow-up"></i></a>'
                            '<span class="spacer"></span>'
                            '<button onclick="window.__openSearchPalette&&window.__openSearchPalette()" title="Search (/)"><i data-lucide="search"></i></button>'
                            '</div>'
                            '<div class="subbar"><span class="crumbs">' + crumbs_html + '</span></div>'
                            '<ul>' + ''.join(rows) + '</ul>'
                            '<script src="https://cdn.jsdelivr.net/npm/lucide@0.460.0/dist/umd/lucide.min.js"></script>'
                            '<script>if(window.lucide)lucide.createIcons();</script>'
                            '<script>' + PALETTE_JS + '</script>'
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

                    ai_flag = 'true' if os.environ.get('SPEAKIT_LLM_ENABLED') == '1' else 'false'
                    body = (MD_TEMPLATE
                            .replace('__PALETTE_CSS__', PALETTE_CSS)
                            .replace('__PALETTE_JS__', PALETTE_JS)
                            .replace('__AI_FLAG__', ai_flag)
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

        let llm = LLMSettings.shared
        var env = ProcessInfo.processInfo.environment
        env["SPEAKIT_LLM_ENABLED"] = llm.enabled ? "1" : "0"
        env["SPEAKIT_LLM_KIND"] = llm.provider.rawValue
        env["SPEAKIT_LLM_URL"] = llm.baseURL
        env["SPEAKIT_LLM_MODEL"] = llm.model
        env["SPEAKIT_LLM_KEY"] = llm.apiKey
        env["SPEAKIT_EDGE_TTS_BIN"] = EdgeTTSProvider.binaryPath ?? ""
        env["SPEAKIT_EDGE_TTS_VOICE"] = UserDefaults.standard.string(forKey: "SpeakIt.voice.edge-tts")
            ?? "en-GB-SoniaNeural"
        proc.environment = env

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

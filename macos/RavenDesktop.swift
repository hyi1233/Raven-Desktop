import Cocoa
import WebKit
import CryptoKit

// Raven Desktop -- a native macOS window around the Raven page.
// No browser tab: the app IS the window. The gateway is a resident process
// started by launch.sh, so closing this window leaves the engine running.
//
// Diagnostics live ONLY in this wrapper: a WKUserScript injected into this
// WKWebViewConfiguration, a fixed in-memory ring, and a file written only when
// an anomaly is detected or the reader exports one. Nothing here is served to
// the browser/web client, and the gateway and its bundle are never touched.

// MARK: - Diagnostics model

private struct DiagEvent {
    let t: Int64                 // epoch ms, same clock as the page's Date.now()
    let layer: String           // boot | conn | nav | bridge | ui | page | interaction
    let ev: String
    let fields: [String: String]
}

private func diagNow() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

/// Whitelist: even if the page sent something unexpected, only these keys are
/// ever kept. Every value is also length-capped, so no draft text can reach disk.
private let diagKeys: Set<String> = [
    "page", "key", "code", "keyCode", "composing", "shift", "meta", "ctrl", "alt",
    "repeat", "len", "active", "data", "inputType", "href", "method", "rpcLen",
    "bytes", "msgLen", "kind", "handler", "verbose", "busy", "selStart", "selEnd",
    "reason", "url", "code_ns", "attempt", "title"
]

private func diagStr(_ v: Any) -> String {
    let s: String
    if let n = v as? NSNumber { s = n.stringValue }
    else { s = String(describing: v) }
    if s.count > 120 { return "<\(s.count)>" }
    return s
}

/// Separate handler object: WKUserContentController retains its message handler,
/// so a weak owner avoids the classic WKWebView retain cycle.
private final class DiagBridge: NSObject, WKScriptMessageHandler {
    weak var owner: Diagnostics?
    init(owner: Diagnostics) { self.owner = owner }
    func userContentController(_ ucc: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "ravenDiag",
              let body = message.body as? [String: Any],
              let batch = body["batch"] as? [[String: Any]] else { return }
        owner?.ingest(batch)
    }
}

private final class Diagnostics {
    static let shared = Diagnostics()

    private let maxEvents = 4000
    private let maxAgeMs: Int64 = 60_000
    private let dumpCooldownMs: Int64 = 20_000
    private let beforeMs: Int64 = 15_000
    private let afterMs: Int64 = 3_000
    private let maxPackages = 3
    private let filePrefix = "Raven-Diagnostics-"

    private var ring: [DiagEvent] = []
    private var lastDump: Int64 = 0

    // Session state for the split-send detectors. All on the main thread.
    private var lastRealEnter: Int64 = 0
    private var lastClickGo: Int64 = 0
    private var lastLenZero: Int64 = 0

    // MARK: ingest

    func ingest(_ batch: [[String: Any]]) {
        let now = diagNow()
        for raw in batch {
            guard let layer = raw["layer"] as? String,
                  let ev = raw["ev"] as? String else { continue }
            let t = (raw["t"] as? NSNumber)?.int64Value ?? now
            var f: [String: String] = [:]
            for k in diagKeys where raw[k] != nil { f[k] = diagStr(raw[k]!) }
            ring.append(DiagEvent(t: t, layer: layer, ev: ev, fields: f))
            detect(ev: ev, f: f, t: t)
        }
        trim(now: now)
    }

    /// Native-layer events (the wrapper's own lifecycle), same ring, same clock.
    func note(_ layer: String, _ ev: String, _ extra: [String: Any] = [:]) {
        let now = diagNow()
        var f: [String: String] = [:]
        for (k, v) in extra where diagKeys.contains(k) { f[k] = diagStr(v) }
        ring.append(DiagEvent(t: now, layer: layer, ev: ev, fields: f))
        trim(now: now)
    }

    /// A native-layer failure is itself an anomaly: dump immediately.
    func anomaly(_ reason: String) {
        let t = diagNow()
        note("anomaly", "trigger", ["reason": reason])
        scheduleDump(reason: reason, at: t)
    }

    private func trim(now: Int64) {
        while ring.count > maxEvents { ring.removeFirst() }
        while let first = ring.first, now - first.t > maxAgeMs { ring.removeFirst() }
    }

    // MARK: anomaly rules

    private func detect(ev: String, f: [String: String], t: Int64) {
        switch ev {
        case "keydown":
            if f["key"] == "Enter" && f["keyCode"] == "13" && f["composing"] == "0" {
                lastRealEnter = t
            }
        case "click:go":
            lastClickGo = t
        case "after:enter":
            if f["len"] == "0" {
                lastLenZero = t
                if t - lastRealEnter > 2000 && t - lastClickGo > 2000 {
                    scheduleDump(reason: "field-cleared-without-real-Enter", at: t)
                }
            }
        case "after:compositionend":
            if f["len"] == "0" && t - lastRealEnter > 2000 && t - lastClickGo > 2000 {
                scheduleDump(reason: "composition-cleared", at: t)
            }
        case "rpc.send":
            guard f["method"] == "turn.send" else { break }
            let userSent = (t - lastRealEnter <= 2000) || (t - lastClickGo <= 2000)
            if !userSent {
                // A send with NO corresponding user action is the actual bug
                // (one draft leaving as several messages). Two deliberate
                // Enters in 5s are normal and must not produce a package.
                scheduleDump(reason: "send-without-user-action", at: t)
            }
        case "error":
            scheduleDump(reason: "page-error", at: t)
        default:
            break
        }
    }

    private func scheduleDump(reason: String, at t: Int64) {
        let now = diagNow()
        if now - lastDump < dumpCooldownMs { return }   // no runaway files
        lastDump = now
        // "after 3s" tail: the anomaly's consequences land a beat later.
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(afterMs) / 1000.0) { [weak self] in
            self?.writePackage(reason: reason, at: t, manual: false)
        }
    }

    /// Manual export is the guaranteed fallback: it always writes, no cooldown,
    /// even when no automatic rule matched (silent wrong-behaviour bugs).
    func exportManual() {
        writePackage(reason: "manual", at: diagNow(), manual: true)
    }

    // MARK: export

    private func writePackage(reason: String, at t: Int64, manual: Bool) {
        let hi = manual ? diagNow() : t + afterMs
        let window = ring.filter { $0.t >= t - beforeMs && $0.t <= hi }

        var out = "Raven Desktop diagnostics\n"
        out += "generated: \(Date().description)\n"
        out += "trigger: \(reason) (\(manual ? "manual" : "auto"))\n"
        out += "window: \(t - beforeMs) .. \(hi) ms (epoch)\n"
        out += "events: \(window.count) of \(ring.count) buffered\n\n"

        out += "== environment ==\n"
        let info = Bundle.main.infoDictionary ?? [:]
        out += "app: Raven \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))\n"
        out += "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        out += "WebKit: \(Bundle(identifier: "com.apple.WebKit")?.infoDictionary?["CFBundleShortVersionString"] ?? "?")\n"
        out += "servedBundleSHA256: \(servedBundleHash())\n"
        out += "scope: WKUserScript in this app's WKWebView only; web client and gateway untouched\n"
        out += "privacy: no message text recorded; payloads replaced by <length>\n\n"

        out += "== summary ==\n"
        let sends = window.filter { $0.ev == "rpc.send" && $0.fields["method"] == "turn.send" }
        out += "turn.send count: \(sends.count)\n"
        out += "turn.send rpcLen: \(sends.map { $0.fields["rpcLen"] ?? "?" }.joined(separator: ", "))\n"
        let realEnters = window.filter { $0.ev == "keydown" && $0.fields["key"] == "Enter" && $0.fields["keyCode"] == "13" }.count
        let pseudoEnters = window.filter { $0.ev == "keydown" && $0.fields["key"] == "Enter" && $0.fields["keyCode"] == "229" }.count
        out += "real Enter (13): \(realEnters)   pseudo Enter (229): \(pseudoEnters)\n"
        out += "click:go: \(window.filter { $0.ev == "click:go" }.count)\n"
        out += "after:enter len=0: \(window.filter { $0.ev == "after:enter" && $0.fields["len"] == "0" }.count)\n"
        out += "compositionend: \(window.filter { $0.ev == "compositionend" }.count)\n"
        out += "native anomalies: \(window.filter { $0.layer == "anomaly" }.map { $0.fields["reason"] ?? "?" }.joined(separator: ", "))\n\n"

        out += "== timeline ==\n"
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        for e in window {
            let d = Date(timeIntervalSince1970: Double(e.t) / 1000.0)
            var parts: [String] = []
            for k in diagKeys.sorted() where e.fields[k] != nil { parts.append("\(k)=\(e.fields[k]!)") }
            out += "\(df.string(from: d)) \(e.layer) \(e.ev) \(parts.joined(separator: " "))\n"
        }

        let desktop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
        let df2 = DateFormatter()
        df2.dateFormat = "yyyyMMdd-HHmmss"
        let url = desktop.appendingPathComponent("\(filePrefix)\(df2.string(from: Date())).txt")
        do {
            try? FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
            try out.write(to: url, atomically: true, encoding: .utf8)
            rotate(desktop)
            if manual {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                let a = NSAlert()
                a.messageText = "诊断已导出"
                a.informativeText = url.lastPathComponent
                a.addButton(withTitle: "好")
                a.runModal()
            } else {
                NSLog("raven-diag: wrote \(url.lastPathComponent) (\(reason))")
            }
        } catch {
            NSLog("raven-diag: export failed: \(error)")
        }
    }

    private func rotate(_ dir: URL) {
        guard let list = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let ours = list.filter { $0.lastPathComponent.hasPrefix(filePrefix) && $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for u in ours.prefix(max(0, ours.count - maxPackages)) {
            try? FileManager.default.removeItem(at: u)
        }
    }

    /// Read-only proof that the shared web bundle was not modified by us.
    private func servedBundleHash() -> String {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/uv/tools/raven/lib")
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return "unknown" }
        for d in dirs where d.hasPrefix("python") {
            let p = base.appendingPathComponent(d)
                .appendingPathComponent("site-packages/raven/ui/dist/index.html")
            if let data = try? Data(contentsOf: p, options: .mappedIfSafe) {
                return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
        }
        return "unknown"
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {

    private var window: NSWindow!
    private var webView: WKWebView!
    private var busy = false
    private var loadedPage = false

    private let localHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    private let diag = Diagnostics.shared
    private lazy var diagBridge = DiagBridge(owner: diag)
    /// Emergency kill switch. Normal launches always collect (in memory only).
    private let diagOff = ProcessInfo.processInfo.environment["RAVEN_DIAG_OFF"] == "1"
    private let diagVerbose = ProcessInfo.processInfo.environment["RAVEN_DIAG_VERBOSE"] == "1"

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        diag.note("boot", "launch", ["verbose": diagVerbose ? 1 : 0])
        buildMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        reconnect()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - UI

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Raven", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide Raven", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Raven", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let reconnectItem = NSMenuItem(title: "Reconnect", action: #selector(reconnectAction), keyEquivalent: "R")
        reconnectItem.target = self
        reconnectItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(reconnectItem)
        let reloadItem = NSMenuItem(title: "Reload Page", action: #selector(reloadAction), keyEquivalent: "r")
        reloadItem.target = self
        fileMenu.addItem(reloadItem)
        fileMenu.addItem(NSMenuItem.separator())
        let exportItem = NSMenuItem(title: "导出诊断…", action: #selector(exportDiagnosticsAction), keyEquivalent: "d")
        exportItem.target = self
        exportItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(exportItem)
        fileMenu.addItem(NSMenuItem.separator())
        let closeItem = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(closeItem)
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [
            ("Undo", #selector(UndoManager.undo), "z"),
            ("Redo", #selector(UndoManager.redo), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a")
        ] as [(String, Selector, String)] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            editMenu.addItem(item)
        }
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    private func buildWindow() {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(1280, visible.width * 0.9)
        let height = min(860, visible.height * 0.9)
        let rect = NSRect(x: 0, y: 0, width: width, height: height)

        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Raven"
        window.setFrameAutosaveName("RavenDesktopMainWindow")
        window.minSize = NSSize(width: 880, height: 560)
        window.center()
        window.isReleasedWhenClosed = false

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let pagePrefs = WKWebpagePreferences()
        pagePrefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = pagePrefs
        installDiagnostics(config)

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.autoresizingMask = [.width, .height]
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Diagnostics installation (this WKWebView only)

    private func installDiagnostics(_ config: WKWebViewConfiguration) {
        guard !diagOff else {
            diag.note("bridge", "injection-off")
            return
        }
        let ucc = config.userContentController
        guard let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/scripts/diagnostics.js") as URL?,
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("raven-diag: script missing")
            diag.note("bridge", "injection-missing")
            diag.anomaly("script-injection-missing")
            return
        }
        ucc.add(diagBridge, name: "ravenDiag")
        if diagVerbose {
            ucc.addUserScript(WKUserScript(source: "window.__ravenDiagVerbose = true;",
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        ucc.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                       forMainFrameOnly: true))
        diag.note("bridge", "injected", ["verbose": diagVerbose ? 1 : 0])
    }

    @objc private func exportDiagnosticsAction() { diag.exportManual() }

    // MARK: - Bootstrap

    @objc private func reconnectAction() {
        diag.note("ui", "action", ["reason": "menu:reconnect"])
        reconnect()
    }

    @objc private func reloadAction() {
        diag.note("ui", "action", ["reason": "menu:reload"])
        if loadedPage { webView.reload() } else { reconnect() }
    }

    private var reconnectTimes: [Int64] = []

    private func reconnect() {
        guard !busy else { return }
        busy = true
        loadedPage = false
        let now = diagNow()
        reconnectTimes.append(now)
        reconnectTimes.removeAll { now - $0 > 60_000 }
        diag.note("conn", "reconnect", ["attempt": reconnectTimes.count])
        if reconnectTimes.count >= 3 { diag.anomaly("repeated-reconnect") }
        showStatus("Starting Raven...", retry: false)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let urlString = AppDelegate.bootstrapURL()
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if let s = urlString, let u = URL(string: s) {
                    self.diag.note("conn", "bootstrap-ok", ["url": AppDelegate.strip(s)])
                    self.webView.load(URLRequest(url: u))
                } else {
                    self.diag.note("conn", "bootstrap-failed")
                    self.diag.anomaly("gateway-bootstrap-failed")
                    self.showStatus("The gateway did not start. Press Cmd-Shift-R to retry, or check ~/.raven/logs/.", retry: true)
                }
            }
        }
    }

    private static func strip(_ s: String) -> String {
        guard let u = URLComponents(string: s) else { return "<invalid>" }
        let scheme = u.scheme.map { $0 + "://" } ?? ""
        return scheme + [u.host, u.port.map { ":\($0)" }, u.path].compactMap { $0 }.joined()
    }

    private static func bootstrapURL() -> String? {
        let task = Process()
        let launcher = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/scripts/launch.sh")
        task.executableURL = launcher
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s, s.hasPrefix("http://") || s.hasPrefix("https://") else { return nil }
        return s
    }

    private func showStatus(_ message: String, retry: Bool) {
        loadedPage = false
        let button = retry
            ? "<p style=\"margin-top:18px\"><a href=\"raven://retry\" style=\"color:#7aa2f7;font-size:14px\">Reconnect</a></p>"
            : ""
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{height:100%;margin:0;display:flex;align-items:center;justify-content:center;
        font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#101216;color:#e6e8ec}
        @media (prefers-color-scheme: light){html,body{background:#f6f7f9;color:#1d1f23}}
        .box{text-align:center;max-width:520px;padding:24px}
        .mark{font-size:40px}.title{font-size:22px;font-weight:600;margin-top:10px}
        .msg{margin-top:12px;opacity:.72;font-size:14px;line-height:1.6}
        a{text-decoration:none}
        </style></head><body><div class="box"><div class="mark">R</div>
        <div class="title">Raven</div><div class="msg">\(message)</div>\(button)</div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow); return
        }
        if url.scheme == "raven" {
            if url.host == "retry" { reconnect() }
            diag.note("nav", "scheme-raven", ["url": url.host ?? ""])
            decisionHandler(.cancel); return
        }
        if isLocal(url) { decisionHandler(.allow); return }
        if url.scheme == "http" || url.scheme == "https" {
            // External links belong to the system browser, not this window.
            NSWorkspace.shared.open(url)
            diag.note("nav", "external", ["url": AppDelegate.strip(url.absoluteString)])
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let t = webView.title, !t.isEmpty, isLocal(webView.url) {
            window.title = t
            loadedPage = true
            diag.note("nav", "finish", ["url": AppDelegate.strip(webView.url?.absoluteString ?? ""), "title": t])
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        diagFailure(error)
        failIfLocal(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        diagFailure(error)
        failIfLocal(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        diag.note("nav", "webcontent-terminated")
        diag.anomaly("webcontent-terminated")
        reconnect()
    }

    private func diagFailure(_ error: Error) {
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }
        diag.note("nav", "fail", ["code_ns": ns.code, "url": AppDelegate.strip(ns.userInfo[NSURLErrorFailingURLErrorKey as String] as? String ?? "")])
        diag.anomaly("navigation-failed")
    }

    private func failIfLocal(_ error: Error) {
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }
        guard let url = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL, isLocal(url) else { return }
        showStatus("The page could not reach the gateway. Press Cmd-Shift-R to retry.", retry: true)
    }

    private func isLocal(_ url: URL?) -> Bool {
        guard let url, let host = url.host else { return false }
        return localHosts.contains(host)
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let url = navigationAction.request.url else { return nil }
        diag.note("ui", "new-window", ["url": AppDelegate.strip(url.absoluteString)])
        if isLocal(url) {
            webView.load(navigationAction.request)
        } else if url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        diag.note("ui", "panel", ["kind": "alert", "msgLen": message.count])
        let alert = NSAlert()
        alert.messageText = "Raven"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        diag.note("ui", "panel", ["kind": "confirm", "msgLen": message.count])
        let alert = NSAlert()
        alert.messageText = "Raven"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

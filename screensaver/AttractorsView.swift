import ScreenSaver
import WebKit

// Screensaver that hosts ../index.html in a WKWebView.
// The page reads its mode and settings from window.__SAVER__, injected before it loads;
// in the options sheet it posts settings back through the "saver" message handler.
@objc(AttractorsView)
final class AttractorsView: ScreenSaverView, WKScriptMessageHandler {
    private static let moduleName = "com.avc.attractors"
    private static let settingsKey = "settings"

    private var webView: WKWebView?
    private var configWindow: NSWindow?
    private var configWebView: WKWebView?
    private var pendingSettings: String?

    private var defaults: ScreenSaverDefaults? { ScreenSaverDefaults(forModuleWithName: Self.moduleName) }

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1   // the web page drives its own animation
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        let wv = makeWebView(mode: isPreview ? "preview" : "saver", frame: bounds)
        addSubview(wv)
        webView = wv

        // Since macOS 14 the host process keeps old instances alive; drop the page when the saver stops
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(willStop), name: Notification.Name("com.apple.screensaver.willstop"), object: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func willStop(_ note: Notification) {
        guard !isPreview else { return }
        webView?.removeFromSuperview()
        webView = nil
    }

    // Keep mouse events away from the page so moving the mouse still dismisses the saver
    override func hitTest(_ point: NSPoint) -> NSView? { self }

    private func makeWebView(mode: String, frame: NSRect) -> WKWebView {
        let config = WKWebViewConfiguration()
        let stored = defaults?.string(forKey: Self.settingsKey) ?? "null"
        let script = "window.__SAVER__ = { mode: '\(mode)', cfg: \(stored) };"
        config.userContentController.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if mode == "config" {
            config.userContentController.add(self, name: "saver")
        }

        let wv = WKWebView(frame: frame, configuration: config)
        wv.autoresizingMask = [.width, .height]
        wv.setValue(false, forKey: "drawsBackground")
        if let url = Bundle(for: Self.self).url(forResource: "index", withExtension: "html") {
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return wv
    }

    // MARK: - Options sheet

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        let size = NSSize(width: 1040, height: 700), bar: CGFloat = 52
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Attractors"
        window.minSize = NSSize(width: 760, height: 520)

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        let wv = makeWebView(mode: "config", frame: NSRect(x: 0, y: bar, width: size.width, height: size.height - bar))
        content.addSubview(wv)

        let ok = NSButton(title: "OK", target: self, action: #selector(confirmSheet))
        ok.keyEquivalent = "\r"
        ok.bezelStyle = .rounded
        ok.frame = NSRect(x: size.width - 112, y: 12, width: 96, height: 30)
        ok.autoresizingMask = [.minXMargin, .maxYMargin]

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSheet))
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: size.width - 214, y: 12, width: 96, height: 30)
        cancel.autoresizingMask = [.minXMargin, .maxYMargin]

        content.addSubview(ok)
        content.addSubview(cancel)
        window.contentView = content

        configWindow = window
        configWebView = wv
        pendingSettings = nil
        return window
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let json = message.body as? String { pendingSettings = json }
    }

    @objc private func confirmSheet() {
        if let json = pendingSettings, let defaults {
            defaults.set(json, forKey: Self.settingsKey)
            defaults.synchronize()
            // restart the visible saver/preview so it picks up the new settings
            webView?.removeFromSuperview()
            let wv = makeWebView(mode: isPreview ? "preview" : "saver", frame: bounds)
            addSubview(wv)
            webView = wv
        }
        closeSheet()
    }

    @objc private func cancelSheet() { closeSheet() }

    private func closeSheet() {
        configWebView?.configuration.userContentController.removeScriptMessageHandler(forName: "saver")
        configWebView = nil
        if let window = configWindow {
            if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
        }
        configWindow = nil
    }
}

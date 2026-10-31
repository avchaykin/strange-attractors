import AppKit
import ServiceManagement
import WebKit

// Menu-bar app that shows ../index.html as a live desktop wallpaper (under the desktop icons, on
// every screen and Space) and, optionally, as a screensaver after the chosen idle time that closes
// on any input. The Settings window hosts the same page in config mode; the page posts its settings
// through the "saver" message handler.

private let settingsKey = "settings"
private let idleKey = "idleMinutes"          // 0 = never start automatically
private let launchedKey = "hasLaunchedBefore"
private let wallpaperKey = "wallpaperOn"

private func pageURL() -> URL? { Bundle.main.url(forResource: "index", withExtension: "html") }

private func makeWebView(mode: String, frame: NSRect, handler: WKScriptMessageHandler?) -> WKWebView {
    let config = WKWebViewConfiguration()
    let stored = UserDefaults.standard.string(forKey: settingsKey) ?? "null"
    config.userContentController.addUserScript(WKUserScript(
        source: "window.__SAVER__ = { mode: '\(mode)', cfg: \(stored) };",
        injectionTime: .atDocumentStart, forMainFrameOnly: true))
    if let handler { config.userContentController.add(handler, name: "saver") }
    let wv = WKWebView(frame: frame, configuration: config)
    wv.autoresizingMask = [.width, .height]
    wv.setValue(false, forKey: "drawsBackground")
    if let url = pageURL() { wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
    return wv
}

/// Borderless windows can't become key by default; the saver needs key events to dismiss.
final class SaverWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Swallows mouse events so the page never sees them (no dragging in saver mode).
final class ShieldView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { self }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var saverWindows: [NSWindow] = []
    private var eventMonitor: Any?
    private var startedAt = Date.distantPast
    private var settingsWindow: NSWindow?
    private var idleTimer: Timer?
    private var launchItem: NSMenuItem!
    private var idleItems: [NSMenuItem] = []
    private var wallpaperItem: NSMenuItem!
    private var wallpaperWindows: [NSWindow] = []
    private var wallpaperReload: Timer?

    private let idleChoices = [1, 2, 5, 10, 15, 20, 30, 60, 0]

    func applicationDidFinishLaunching(_ note: Notification) {
        UserDefaults.standard.register(defaults: [idleKey: 0, wallpaperKey: true])
        buildMenu()
        updateWallpaper()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        idleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.checkIdle() }
        if !UserDefaults.standard.bool(forKey: launchedKey) {
            UserDefaults.standard.set(true, forKey: launchedKey)
            showSettings()
        }
    }

    // Opening the app again from Finder or Spotlight shows Settings.
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return false
    }

    // MARK: - Menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "scribble.variable", accessibilityDescription: "Attractors")

        let menu = NSMenu()
        wallpaperItem = NSMenuItem(title: "Live Wallpaper", action: #selector(toggleWallpaper), keyEquivalent: "w")
        wallpaperItem.target = self
        menu.addItem(wallpaperItem)
        menu.addItem(withTitle: "Start Screensaver Now", action: #selector(startNow), keyEquivalent: "s").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())

        let idleMenu = NSMenu()
        for minutes in idleChoices {
            let title = minutes == 0 ? "Never" : minutes == 1 ? "1 minute" : "\(minutes) minutes"
            let item = NSMenuItem(title: title, action: #selector(chooseIdle(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes
            idleMenu.addItem(item)
            idleItems.append(item)
        }
        let idleItem = NSMenuItem(title: "Screensaver After", action: nil, keyEquivalent: "")
        idleItem.submenu = idleMenu
        menu.addItem(idleItem)

        launchItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        menu.addItem(launchItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Attractors", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
        refreshMenu()
    }

    private func refreshMenu() {
        let current = UserDefaults.standard.integer(forKey: idleKey)
        idleItems.forEach { $0.state = $0.tag == current ? .on : .off }
        launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        wallpaperItem.state = UserDefaults.standard.bool(forKey: wallpaperKey) ? .on : .off
    }

    // MARK: - Wallpaper

    @objc private func toggleWallpaper() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: wallpaperKey), forKey: wallpaperKey)
        updateWallpaper()
        refreshMenu()
    }

    @objc private func screensChanged() { updateWallpaper() }

    /// Rebuilds the wallpaper windows from scratch: on toggle, screen changes and new settings.
    private func updateWallpaper() {
        wallpaperWindows.forEach { $0.orderOut(nil); $0.contentView = nil }
        wallpaperWindows.removeAll()
        guard UserDefaults.standard.bool(forKey: wallpaperKey) else { return }
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            // the desktop level sits above the desktop picture and below the desktop icons
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.backgroundColor = .windowBackgroundColor
            window.contentView = makeWebView(mode: "wallpaper", frame: NSRect(origin: .zero, size: screen.frame.size), handler: nil)
            window.orderFrontRegardless()
            wallpaperWindows.append(window)
        }
    }

    @objc private func chooseIdle(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: idleKey)
        refreshMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nYou can add Attractors manually in System Settings → General → Login Items."
            alert.runModal()
        }
        refreshMenu()
    }

    @objc private func openSettings() { showSettings() }
    @objc private func startNow() { startSaver() }

    // MARK: - Idle detection

    private func checkIdle() {
        let minutes = UserDefaults.standard.integer(forKey: idleKey)
        guard minutes > 0, saverWindows.isEmpty, settingsWindow == nil else { return }
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        if idle >= Double(minutes * 60) { startSaver() }
    }

    // MARK: - Saver

    private func startSaver() {
        guard saverWindows.isEmpty else { return }
        settingsWindow?.close()
        for screen in NSScreen.screens {
            let window = SaverWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true

            let shield = ShieldView(frame: NSRect(origin: .zero, size: screen.frame.size))
            shield.autoresizingMask = [.width, .height]
            shield.addSubview(makeWebView(mode: "saver", frame: shield.bounds, handler: nil))
            window.contentView = shield
            window.orderFrontRegardless()
            saverWindows.append(window)
        }
        saverWindows.first?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.hide()
        startedAt = Date()

        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                           .mouseMoved, .scrollWheel, .flagsChanged]
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            // ignore stray mouse moves right after the windows appear
            if event.type == .mouseMoved {
                let jump = abs(event.deltaX) + abs(event.deltaY)
                if Date().timeIntervalSince(self.startedAt) < 1.5 || jump < 3 { return nil }
            }
            self.stopSaver()
            return nil
        }
    }

    private func stopSaver() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        saverWindows.forEach { $0.orderOut(nil); $0.contentView = nil }
        saverWindows.removeAll()
        NSCursor.unhide()
    }

    // MARK: - Settings window

    private func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let size = NSSize(width: 1100, height: 720)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Attractors Settings"
        window.minSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = makeWebView(mode: "config", frame: NSRect(origin: .zero, size: size), handler: self)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    func windowWillClose(_ note: Notification) {
        guard let window = note.object as? NSWindow, window === settingsWindow else { return }
        (window.contentView as? WKWebView)?.configuration.userContentController.removeScriptMessageHandler(forName: "saver")
        window.contentView = nil
        settingsWindow = nil
    }

    // Settings are saved as soon as they change in the page.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let json = message.body as? String else { return }
        UserDefaults.standard.set(json, forKey: settingsKey)
        // settings arrive on every slider move; refresh the wallpaper once they settle
        wallpaperReload?.invalidate()
        wallpaperReload = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in self?.updateWallpaper() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

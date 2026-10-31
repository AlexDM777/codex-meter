import AppKit
import WebKit
import ServiceManagement
import UniformTypeIdentifiers

final class WidgetWebView: WKWebView {
    weak var owner: MeterApp?
    override func hitTest(_ point: NSPoint) -> NSView? { self }
    override func mouseDown(with event: NSEvent) { if event.clickCount == 2 { owner?.toggleSize() } else { window?.performDrag(with: event); owner?.save() } }
    override func rightMouseDown(with event: NSEvent) { if let menu = owner?.contextMenu() { NSMenu.popUpContextMenu(menu, with: event, for: self) } }
    override func scrollWheel(with event: NSEvent) { owner?.setWidth((owner?.width ?? 500) + (event.scrollingDeltaY > 0 ? 40 : -40)) }
}
final class StatusTracker: NSView {
    weak var owner: MeterApp?
    override func updateTrackingAreas() { for area in trackingAreas { removeTrackingArea(area) }; addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)); super.updateTrackingAreas() }
    override func mouseEntered(with event: NSEvent) { owner?.showHover() }
    override func mouseDown(with event: NSEvent) { if event.clickCount == 2 { owner?.trayDoubleClick() } else { owner?.showHover() } }
    override func rightMouseDown(with event: NSEvent) { if let menu = owner?.contextMenu() { NSMenu.popUpContextMenu(menu, with: event, for: self) } }
}
final class MeterApp: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    let profile: URL
    let root: URL
    var library: Library!
    let rpc = CodexRPC()
    var updates: MacUpdates!
    var defaults: [String: Any] = [:]
    var usage = Usage()
    var signedIn = false, account = "", status = "Подключение…", loginID: String?
    var width: CGFloat = 500
    var skinID = "glass-night", language = "ru", selectedMinutes = 0, pinned = true, randomSkin = false, autoUpdate = true, opacity = 1.0
    var previewSkin: String?, compactFrame: NSRect?
    var widget: NSPanel!, hover: NSPanel!, settings: NSWindow?
    var widgetWeb: WidgetWebView!, hoverWeb: WKWebView!, settingsWeb: WKWebView?
    var statusItem: NSStatusItem!, tracker: StatusTracker!
    var timers: [Timer] = []
    var ready = Set<ObjectIdentifier>()
    let demo: Bool, renderDirectory: String?
    var renderIndex = 0, renderCapturing = false, resizing = false
    var renderPhase = "widget"
    override init() {
        root = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        profile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexMeter", isDirectory: true)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-test"), args.count > i+1 { renderDirectory = args[i+1] } else { renderDirectory = nil }
        demo = args.contains("--demo") || renderDirectory != nil
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try FileManager.default.createDirectory(at: profile.appendingPathComponent("account"), withIntermediateDirectories: true); library = try Library(root: root, profile: profile) } catch { if renderDirectory != nil { fputs("Resource load failed: \(error)\n", stderr); exit(1) }; alert(error.localizedDescription); NSApp.terminate(nil); return }
        if let data = try? Data(contentsOf: profile.appendingPathComponent("settings.json")), let values = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { defaults = values }
        width = min(1000, max(100, CGFloat((defaults["width"] as? NSNumber)?.doubleValue ?? 500))); skinID = defaults["skin"] as? String ?? "glass-night"; language = defaults["language"] as? String ?? "ru"; if !languageCodes.contains(language) { language = "ru" }
        selectedMinutes = defaults["selectedMinutes"] as? Int ?? 0; pinned = defaults["topmost"] as? Bool ?? true; randomSkin = defaults["randomSkinOnStartup"] as? Bool ?? false; autoUpdate = defaults["autoUpdate"] as? Bool ?? true; opacity = defaults["opacity"] as? Double ?? 1
        if randomSkin && !demo { skinID = library.themes.filter { $0.id != skinID }.randomElement()?.id ?? skinID }
        updates = MacUpdates(profile: profile); updates.changed = { [weak self] in self?.sendAll() }
        widget = NSPanel(contentRect: NSRect(x: 80, y: 150, width: width, height: width), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false); widget.isFloatingPanel = true; widget.isOpaque = false; widget.backgroundColor = .clear; widget.hasShadow = true; widget.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; widget.level = pinned ? .floating : .normal; widget.alphaValue = opacity; widget.delegate = self
        widgetWeb = makeWeb(kind: "widget") as? WidgetWebView; widgetWeb.owner = self; widget.contentView = widgetWeb
        if let x = defaults["left"] as? Double, let y = defaults["top"] as? Double { widget.setFrameOrigin(NSPoint(x: x, y: y)) }
        if !(NSScreen.screens.contains { $0.visibleFrame.intersects(widget.frame) }) { widget.center() }
        hover = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 570), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false); hover.isOpaque = false; hover.backgroundColor = .clear; hover.hasShadow = true; hover.level = .popUpMenu; hoverWeb = makeWeb(kind: "hover"); hover.contentView = hoverWeb
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button { button.title = "—%"; button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold); tracker = StatusTracker(frame: button.bounds); tracker.autoresizingMask = [.width, .height]; tracker.owner = self; button.addSubview(tracker) }
        if defaults["startHidden"] as? Bool != true || demo { widget.orderFrontRegardless() }
        rpc.notification = { [weak self] method, params in if method == "account/rateLimits/updated" { self?.usage = Usage.parse(params); self?.sendAll() }; if method == "account/login/completed" || method == "account/updated" { self?.refresh() } }
        rpc.disconnected = { [weak self] in self?.status = "Нет соединения • ПКМ: обновить"; self?.sendAll() }
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in guard let self = self, self.renderDirectory == nil, self.hover.isVisible else { return }; let point = NSEvent.mouseLocation; let buttonFrame = self.statusItem.button.flatMap { $0.window?.convertToScreen($0.convert($0.bounds, to: nil)) } ?? .zero; if !self.hover.frame.insetBy(dx: -12, dy: -12).contains(point) && !buttonFrame.insetBy(dx: -12, dy: -16).contains(point) { self.hover.orderOut(nil) } })
        if demo { signedIn = true; account = "demo@example.com"; usage = Usage(windows: [Quota(minutes: 300, remaining: 72, reset: Date().timeIntervalSince1970+15540), Quota(minutes: 10080, remaining: 67, reset: Date().timeIntervalSince1970+273960)], plan: "prolite", resets: 2); status = ""; if renderDirectory != nil { timers.append(Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { _ in fputs("Render timed out\n", stderr); exit(1) }) } } else { connect(); timers.append(Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in self?.checkUpdates() }); timers.append(Timer.scheduledTimer(withTimeInterval: 21600, repeats: true) { [weak self] _ in self?.checkUpdates() }) }
    }
    func makeWeb(kind: String) -> WKWebView {
        let config = WKWebViewConfiguration(); config.userContentController.add(self, name: "meter")
        let web: WKWebView = kind == "widget" ? WidgetWebView(frame: .zero, configuration: config) : WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self; web.setValue(false, forKey: "drawsBackground"); web.autoresizingMask = [.width, .height]
        web.loadFileURL(root.appendingPathComponent("ui.html"), allowingReadAccessTo: root)
        web.identifier = NSUserInterfaceItemIdentifier(kind)
        return web
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready.insert(ObjectIdentifier(webView)); if renderDirectory != nil && webView === widgetWeb { renderNext() } else { send(webView) } }
    func send(_ web: WKWebView) {
        guard ready.contains(ObjectIdentifier(web)) else { return }
        let effective = previewSkin ?? skinID
        let payload: [String: Any] = ["kind": web.identifier?.rawValue ?? "widget", "selectedSkin": skinID, "test": renderDirectory != nil, "skin": effective, "themes": library.themes.map(\.json), "strings": library.strings, "language": language, "usage": usage.json, "account": account, "signedIn": signedIn, "status": tr(status), "selectedMinutes": selectedMinutes, "width": Double(width), "autoUpdate": autoUpdate, "randomSkin": randomSkin, "pinned": pinned, "opacity": opacity, "startup": SMAppService.mainApp.status == .enabled, "updateStatus": tr(updates.status), "updateAvailable": updates.available != nil, "updateVersion": updates.available?["version"] as? String ?? "", "updateBusy": updates.busy, "version": appVersion]
        web.evaluateJavaScript("window.receive(" + jsonString(payload) + ")", completionHandler: nil)
    }
    func sendAll() {
        guard widget != nil else { return }
        send(widgetWeb); send(hoverWeb); if let web = settingsWeb { send(web) }
        let q = selectedQuota(); let value = q.map { String(Int($0.remaining.rounded()))+"%" } ?? "—%"
        if let skin = library.themes.first(where: { $0.id == (previewSkin ?? skinID) }) {
            let ink = NSColor(hex: skin.values["ink"] as? String ?? "#EDF5FA")
            let color = q.map { $0.remaining < 10 ? NSColor.systemRed : $0.remaining < 20 ? NSColor.systemOrange : ink } ?? ink
            let fills = ["lcd-green":"#D5EAC1","lcd-blue":"#C3E2FA","tape":"#FAD28B","glass-day":"#E8F1FA","glass-night":"#243444","beskar":"#292724","pilot":"#06170E","imperial":"#D9DAD5"]
            let background = NSColor(hex: skin.values["fill"] as? String ?? fills[skin.id] ?? "#18232E")
            let image = NSImage(size: NSSize(width: 46, height: 22), flipped: false) { rect in
                background.setFill(); NSBezierPath(roundedRect: NSRect(x: 0, y: 2, width: 46, height: 18), xRadius: 5, yRadius: 5).fill()
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: color]
                let text = value as NSString, size = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: (46-size.width)/2, y: (22-size.height)/2), withAttributes: attributes); return true
            }
            statusItem.button?.title = ""; statusItem.button?.image = image; statusItem.button?.imagePosition = .imageOnly
            statusItem.button?.setAccessibilityLabel("CodexMeter " + value)
        }
        if !resizing { resizeWidget() }
    }
    func selectedQuota() -> Quota? { selectedMinutes == 0 ? usage.windows.first(where: { $0.minutes == 10080 }) ?? usage.windows.last : usage.windows.first(where: { $0.minutes == selectedMinutes }) }
    func tr(_ key: String) -> String { library?.translate(key, language) ?? key }
    func save() { guard !demo else { return }; defaults.merge(["width": Double(width), "left": widget?.frame.origin.x ?? 80, "top": widget?.frame.origin.y ?? 150, "skin": skinID, "language": language, "selectedMinutes": selectedMinutes, "topmost": pinned, "randomSkinOnStartup": randomSkin, "autoUpdate": autoUpdate, "opacity": opacity]) { _, new in new }; try? Data(jsonString(defaults).utf8).write(to: profile.appendingPathComponent("settings.json"), options: .atomic) }
    func resizeWidget() { let pair = width > 240 && usage.windows.count == 2; let height = pair ? width/2 : width; var frame = widget.frame; frame.size = NSSize(width: width, height: height); if let screen = widget.screen?.visibleFrame ?? NSScreen.main?.visibleFrame { frame.origin.x = min(max(frame.origin.x, screen.minX), screen.maxX-frame.width); frame.origin.y = min(max(frame.origin.y, screen.minY), screen.maxY-frame.height) }; widget.setFrame(frame, display: true) }
    func setWidth(_ value: CGFloat) { width = min(1000, max(100, value)); resizeWidget(); save(); sendAll() }
    func toggleSize() {
        guard !resizing else { return }
        var target: NSRect
        if let old = compactFrame { compactFrame = nil; width = old.width; target = old }
        else { compactFrame = widget.frame; width = 800; target = widget.frame; target.size = NSSize(width: 800, height: usage.windows.count == 2 ? 400 : 800) }
        resizing = true
        NSAnimationContext.runAnimationGroup({ context in context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.28; self.widget.animator().setFrame(target, display: true) }, completionHandler: { self.resizing = false; self.resizeWidget(); self.save(); self.sendAll() })
        sendAll()
    }
    func trayDoubleClick() { hover.orderOut(nil); if widget.isVisible && width >= 799 { widget.orderOut(nil) } else { widget.orderFrontRegardless(); if width < 799 { compactFrame = nil; toggleSize() } } }
    func hoverHeight() -> CGFloat { let ornate = library.themes.first(where: { $0.id == (previewSkin ?? skinID) })?.values["kind"] as? String == "space"; return (usage.windows.count > 1 ? 620 : 450) + (ornate ? 50 : 0) }
    func showHover() { guard let button = statusItem.button, let window = button.window else { return }; send(hoverWeb); let rect = window.convertToScreen(button.convert(button.bounds, to: nil)); let screen = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame; let h = hoverHeight(); let frame = NSRect(x: min(max(rect.midX-280, screen.minX), screen.maxX-560), y: max(screen.minY, rect.minY-h-8), width: 560, height: h); hover.setFrame(frame, display: true); hover.orderFrontRegardless() }
    func connect() {
        guard !demo else { return }
        guard let url = CodexRPC.find(preferred: defaults["cli"] as? String ?? "") else { status = "Codex не найден • ПКМ: Путь к Codex…"; sendAll(); return }
        rpc.start(executable: url, home: profile.appendingPathComponent("account")) { [weak self] result in switch result { case .success: self?.refresh(); case .failure: self?.status = "Не удалось подключиться • ПКМ: обновить"; self?.sendAll() } }
    }
    func refresh() { guard !demo else { sendAll(); return }; rpc.call("account/read", ["refreshToken": false]) { [weak self] result in guard let self = self else { return }; if case .success(let data) = result, let account = data["account"] as? [String: Any], account["type"] as? String == "chatgpt" { self.signedIn = true; self.account = account["email"] as? String ?? ""; self.rpc.call("account/rateLimits/read") { [weak self] limits in if case .success(let data) = limits { self?.usage = Usage.parse(data); self?.status = "" } else { self?.status = "Данные устарели" }; self?.sendAll() } } else { self.signedIn = false; self.account = ""; self.status = "Требуется вход в ChatGPT"; self.sendAll() } } }
    func login() { if signedIn { rpc.call("account/logout") { [weak self] _ in self?.usage = Usage(); self?.refresh() }; return }; if CodexRPC.find(preferred: defaults["cli"] as? String ?? "") == nil { chooseCLI(); return }; rpc.call("account/login/start", ["type": "chatgpt"]) { [weak self] result in if case .success(let data) = result, let address = data["authUrl"] as? String, let url = URL(string: address), url.scheme == "https", let host = url.host, host == "auth.openai.com" || host.hasSuffix(".openai.com") || host == "chatgpt.com" || host.hasSuffix(".chatgpt.com") { self?.loginID = data["loginId"] as? String; NSWorkspace.shared.open(url) } else if case .failure(let error) = result { self?.alert(error.localizedDescription) } } }
    func chooseCLI() { let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.message = "Select the installed Codex CLI executable"; if picker.runModal() == .OK, let url = picker.url, FileManager.default.isExecutableFile(atPath: url.path) { defaults["cli"] = url.path; save(); connect() } }
    func showSettings() { hover.orderOut(nil); if settings == nil { let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false); w.title = "CodexMeter · " + tr("Настройки"); w.isReleasedWhenClosed = false; w.delegate = self; settingsWeb = makeWeb(kind: "settings"); w.contentView = settingsWeb; w.center(); settings = w }; settings?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); if let web = settingsWeb { send(web) } }
    func windowWillClose(_ notification: Notification) { if let w = notification.object as? NSWindow, w === settings { previewSkin = nil; sendAll() } }
    func applicationWillTerminate(_ notification: Notification) { save(); timers.forEach { $0.invalidate() }; rpc.stop() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { widget.orderFrontRegardless(); return true }
    func alert(_ text: String) { let a = NSAlert(); a.messageText = "CodexMeter"; a.informativeText = text; a.runModal() }
    func checkUpdates() { guard !demo else { return }; updates.check { [weak self] in guard let self = self else { return }; if self.autoUpdate && self.updates.available != nil { self.installUpdate() } } }
    func installUpdate() { updates.install { [weak self] success in if success { NSApp.terminate(nil) } else { self?.alert(self?.tr("Не удалось обновить программу") ?? "Update failed") } } }
    func screenshot() { widgetWeb.takeSnapshot(with: nil) { image, error in if let image = image { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]) } } }
    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ action: String, _ value: Any? = nil) -> NSMenuItem { let i = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: ""); i.target = self; i.representedObject = ["action": action, "value": value ?? ""]; return i }
        let skins = NSMenuItem(title: tr("Скин"), action: nil, keyEquivalent: ""), sub = NSMenu(); for theme in library.themes { let i = item("\(theme.values["number"] ?? 0). \(tr(theme.values["name"] as? String ?? theme.id))", "skin", theme.id); i.state = theme.id == skinID ? .on : .off; sub.addItem(i) }; skins.submenu = sub; menu.addItem(skins)
        let size = NSMenuItem(title: tr("Размер"), action: nil, keyEquivalent: ""), sizes = NSMenu(); for number in [100,200,300,500,800,1000] { sizes.addItem(item(String(number), "size", number)) }; size.submenu = sizes; menu.addItem(size)
        let transparency = NSMenuItem(title: tr("Прозрачность"), action: nil, keyEquivalent: ""), levels = NSMenu(); for n in [20,40,60,80,100] { levels.addItem(item("\(n)%", "opacity", Double(n)/100)) }; transparency.submenu = levels; menu.addItem(transparency)
        let pin = item(tr("Поверх окон"), "pin"); pin.state = pinned ? .on : .off; menu.addItem(pin); menu.addItem(item(tr("Скриншот приложения в буфер"), "screenshot")); menu.addItem(item(tr("Настройки"), "settings")); menu.addItem(item(tr(widget.isVisible ? "Скрыть дисплей в трей" : "Показать дисплей"), "visibility")); menu.addItem(.separator()); menu.addItem(item(tr("Выход из приложения"), "quit")); return menu
    }
    @objc func menuAction(_ item: NSMenuItem) { if let data = item.representedObject as? [String: Any] { perform(data) } }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { guard let data = message.body as? [String: Any] else { return }; perform(data) }
    func perform(_ data: [String: Any]) {
        let action = data["action"] as? String ?? "", value = data["value"]
        switch action {
        case "skin": if let id = value as? String, library.themes.contains(where: { $0.id == id }) { skinID = id; previewSkin = nil }
        case "preview": previewSkin = value as? String
        case "cancelPreview": previewSkin = nil
        case "size": if let n = value as? NSNumber { setWidth(CGFloat(n.doubleValue)) }
        case "opacity": if let n = value as? NSNumber { opacity = min(1, max(0.2, n.doubleValue)); widget.alphaValue = opacity }
        case "pin": pinned.toggle(); widget.level = pinned ? .floating : .normal
        case "settings": showSettings()
        case "language": if let id = value as? String, languageCodes.contains(id) { language = id }
        case "quota": selectedMinutes = (value as? NSNumber)?.intValue ?? 0
        case "random": randomSkin = (value as? Bool) ?? !randomSkin
        case "autoUpdate": autoUpdate = (value as? Bool) ?? !autoUpdate
        case "update": if updates.available != nil { installUpdate() } else { updates.check { [weak self] in self?.sendAll() } }
        case "refresh": refresh()
        case "login": login()
        case "cli": chooseCLI()
        case "guide": if let text = try? String(contentsOf: root.appendingPathComponent("SkinGuide.md"), encoding: .utf8) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
        case "folder": NSWorkspace.shared.open(profile.appendingPathComponent("UserSkins"))
        case "reload": do { try library.reload() } catch { alert(error.localizedDescription) }
        case "import": let p = NSOpenPanel(); p.allowedContentTypes = [.json]; if p.runModal() == .OK, let url = p.url { do { skinID = try library.importSkin(url) } catch { alert(error.localizedDescription) } }
        case "startup": if SMAppService.mainApp.status == .enabled { Task { do { try await SMAppService.mainApp.unregister() } catch { await MainActor.run { self.alert(error.localizedDescription) } }; await MainActor.run { self.sendAll() } } } else { do { try SMAppService.mainApp.register() } catch { alert(error.localizedDescription) } }
        case "visibility": if widget.isVisible { widget.orderOut(nil) } else { widget.orderFrontRegardless() }
        case "screenshot": screenshot()
        case "quit": NSApp.terminate(nil)
        case "painted": if renderDirectory != nil, renderIndex < library.themes.count, value as? String == library.themes[renderIndex].id, !renderCapturing { captureRender() }; return
        case "hoverReady": if renderDirectory != nil, renderIndex < library.themes.count, value as? String == library.themes[renderIndex].id, renderPhase == "hover" { captureHoverRender() }; return
        case "renderError": if renderDirectory != nil { fputs("Image rendering failed\n", stderr); exit(1) }
        default: break
        }
        save(); sendAll()
    }
    func renderNext() { guard renderDirectory != nil else { return }; if renderIndex >= library.themes.count { print("PASS: rendered all \(renderIndex) macOS skins"); NSApp.terminate(nil); return }; renderPhase = "widget"; skinID = library.themes[renderIndex].id; width = 500; resizeWidget(); send(widgetWeb) }
    func captureRender() { guard let directory = renderDirectory, renderIndex < library.themes.count else { return }; renderCapturing = true; let id = library.themes[renderIndex].id; widgetWeb.takeSnapshot(with: nil) { image, error in guard let image = image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) else { fputs("Snapshot failed\n", stderr); exit(1) }; do { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true); try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(id+".png")) } catch { exit(1) }; self.renderPhase = "hover"; self.hover.setFrame(NSRect(x: 80, y: 80, width: 560, height: self.hoverHeight()), display: true); self.hover.orderFrontRegardless(); self.send(self.hoverWeb) } }
    func captureHoverRender() {
        guard let directory = renderDirectory, renderIndex < library.themes.count else { return }; renderPhase = "capturing-hover"
        let id = library.themes[renderIndex].id
        hoverWeb.evaluateJavaScript("document.querySelector('.panel').scrollHeight <= innerHeight") { value, error in
            guard value as? Bool == true else { fputs("Hover content clipped: \(id)\n", stderr); exit(1) }
            self.hoverWeb.takeSnapshot(with: nil) { image, error in
                guard let image = image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
                do { try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(id+"-hover.png")) } catch { exit(1) }
                self.renderIndex += 1; self.renderCapturing = false; self.renderNext()
            }
        }
    }

}
extension NSColor { convenience init(hex: String) { let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")); let n = UInt64(s, radix: 16) ?? 0xA1E2FF; self.init(srgbRed: Double((n>>16)&255)/255, green: Double((n>>8)&255)/255, blue: Double(n&255)/255, alpha: 1) } }

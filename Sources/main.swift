// WindowHome — menu bar tool that brings windows back to the built-in display.
//   ⌃⌥⌘B  move the focused window to the built-in screen
//   ⌃⌥⌘G  gather every window from other screens onto the built-in screen
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Screen helpers

func displayID(_ s: NSScreen) -> CGDirectDisplayID {
    (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
}

func builtInScreen() -> NSScreen? {
    NSScreen.screens.first { CGDisplayIsBuiltin(displayID($0)) != 0 }
}

/// Height of the primary screen (the one at origin 0,0) — used to flip between
/// AppKit (bottom-left origin) and Accessibility (top-left origin) coordinates.
var primaryHeight: CGFloat {
    (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens[0]).frame.height
}

func axToCocoa(_ r: CGRect) -> CGRect {
    CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
}

func cocoaToAX(_ r: CGRect) -> CGRect {
    CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
}

func screen(containing axRect: CGRect) -> NSScreen? {
    let r = axToCocoa(axRect)
    let center = CGPoint(x: r.midX, y: r.midY)
    if let s = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return s }
    return NSScreen.screens.max { a, b in
        let ia = a.frame.intersection(r), ib = b.frame.intersection(r)
        return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
    }
}

// MARK: - Accessibility window helpers

func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
    return v as? T
}

func frame(of win: AXUIElement) -> CGRect? {
    guard let p: AXValue = attr(win, kAXPositionAttribute),
          let s: AXValue = attr(win, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p, .cgPoint, &pt)
    AXValueGetValue(s, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}

func setFrame(_ win: AXUIElement, _ r: CGRect) {
    var pt = r.origin, sz = r.size
    let p = AXValueCreate(.cgPoint, &pt)!, s = AXValueCreate(.cgSize, &sz)!
    // size → position → size: avoids apps clamping size against the old screen
    AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, s)
    AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, p)
    AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, s)
}

func isMovable(_ win: AXUIElement) -> Bool {
    if let min: Bool = attr(win, kAXMinimizedAttribute), min { return false }
    if let fs: Bool = attr(win, "AXFullScreen"), fs { return false }
    let sub: String? = attr(win, kAXSubroleAttribute)
    return sub == nil || sub == kAXStandardWindowSubrole || sub == kAXDialogSubrole
}

/// Move a window onto `target`, keeping its relative position and shrinking it if too big.
func move(_ win: AXUIElement, to target: NSScreen) {
    guard let f = frame(of: win) else { return }
    let src = screen(containing: f)
    let dst = cocoaToAX(target.visibleFrame)
    let w = min(f.width, dst.width), h = min(f.height, dst.height)

    var relX: CGFloat = 0.5, relY: CGFloat = 0.5
    if let src {
        let s = cocoaToAX(src.visibleFrame)
        let freeX = s.width - f.width, freeY = s.height - f.height
        if freeX > 0 { relX = max(0, min(1, (f.minX - s.minX) / freeX)) }
        if freeY > 0 { relY = max(0, min(1, (f.minY - s.minY) / freeY)) }
    }
    let x = dst.minX + (dst.width - w) * relX
    let y = dst.minY + (dst.height - h) * relY
    setFrame(win, CGRect(x: x.rounded(), y: y.rounded(), width: w, height: h))
}

func focusedWindow() -> AXUIElement? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    return attr(ax, kAXFocusedWindowAttribute) ?? attr(ax, kAXMainWindowAttribute)
}

// MARK: - Actions

func ensureTrusted() -> Bool {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(opts)
}

func moveFocusedToBuiltIn() {
    guard ensureTrusted() else { return }
    guard let target = builtInScreen(), let win = focusedWindow() else { NSSound.beep(); return }
    move(win, to: target)
}

func moveFocusedToNextScreen() {
    guard ensureTrusted() else { return }
    let screens = NSScreen.screens
    guard screens.count > 1, let win = focusedWindow(), let f = frame(of: win),
          let cur = screen(containing: f), let i = screens.firstIndex(of: cur) else { NSSound.beep(); return }
    move(win, to: screens[(i + 1) % screens.count])
}

func gatherAllToBuiltIn() {
    guard ensureTrusted() else { return }
    guard let target = builtInScreen() else { NSSound.beep(); return }
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        let wins: [AXUIElement] = attr(ax, kAXWindowsAttribute) ?? []
        for win in wins where isMovable(win) {
            guard let f = frame(of: win), let s = screen(containing: f), s != target else { continue }
            move(win, to: target)
        }
    }
}

// MARK: - Global hotkeys (Carbon — no extra permission needed)

var hotKeyActions: [UInt32: () -> Void] = [:]

func registerHotKey(id: UInt32, keyCode: Int, action: @escaping () -> Void) {
    hotKeyActions[id] = action
    var ref: EventHotKeyRef?
    let hkID = EventHotKeyID(signature: OSType(0x57484F4D), id: id) // 'WHOM'
    RegisterEventHotKey(UInt32(keyCode), UInt32(cmdKey | optionKey | controlKey), hkID,
                        GetApplicationEventTarget(), 0, &ref)
}

func installHotKeyHandler() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var hk = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
        DispatchQueue.main.async { hotKeyActions[hk.id]?() }
        return noErr
    }, 1, &spec, nil, nil)
}

// MARK: - Menu bar UI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    let permItem = NSMenuItem(title: "", action: #selector(openPrivacy), keyEquivalent: "")

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "WindowHome")

        let menu = NSMenu()
        menu.delegate = self
        func add(_ title: String, _ key: String, _ sel: Selector) {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            mi.keyEquivalentModifierMask = [.control, .option, .command]
            mi.target = self
            menu.addItem(mi)
        }
        add("Move Focused Window to Built-in Screen", "b", #selector(doFocused))
        add("Gather All Windows to Built-in Screen", "g", #selector(doGather))
        add("Move Focused Window to Next Screen", "n", #selector(doNext))
        menu.addItem(.separator())
        permItem.target = self
        menu.addItem(permItem)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit WindowHome", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        installHotKeyHandler()
        registerHotKey(id: 1, keyCode: kVK_ANSI_B, action: moveFocusedToBuiltIn)
        registerHotKey(id: 2, keyCode: kVK_ANSI_G, action: gatherAllToBuiltIn)
        registerHotKey(id: 3, keyCode: kVK_ANSI_N, action: moveFocusedToNextScreen)

        _ = ensureTrusted()
    }

    func menuWillOpen(_ menu: NSMenu) {
        let ok = AXIsProcessTrusted()
        permItem.title = ok ? "Accessibility: Allowed ✓" : "Accessibility: Not Allowed — Click to Fix"
        permItem.isEnabled = !ok
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // Menu clicks focus our own menu, so act on the app that was frontmost before.
    @objc func doFocused() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: moveFocusedToBuiltIn) }
    @objc func doNext() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: moveFocusedToNextScreen) }
    @objc func doGather() { gatherAllToBuiltIn() }

    @objc func openPrivacy() {
        _ = ensureTrusted()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSSound.beep() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

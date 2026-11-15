import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

// MARK: - Sidecar (private SidecarCore framework)

final class SidecarController {
    enum Result { case connected, disconnected, unavailable, failed(String) }

    // Load once and keep it loaded; unloading a framework whose classes are in use is unsafe.
    private static let loaded: Bool =
        dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_LAZY) != nil

    private var manager: NSObject? {
        guard Self.loaded, let cls = NSClassFromString("SidecarDisplayManager") as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString("sharedManager")
        guard cls.responds(to: sel) else { return nil }
        return cls.perform(sel)?.takeUnretainedValue() as? NSObject
    }

    private func devices(_ selector: String) -> [NSObject] {
        guard let m = manager else { return [] }
        let sel = NSSelectorFromString(selector)
        guard m.responds(to: sel), let value = m.perform(sel)?.takeUnretainedValue() else { return [] }
        return (value as? [NSObject]) ?? []
    }

    private func name(of device: NSObject) -> String {
        for key in ["name", "displayName", "deviceName"] {
            let sel = NSSelectorFromString(key)
            if device.responds(to: sel), let s = device.perform(sel)?.takeUnretainedValue() as? String { return s }
        }
        return "iPad"
    }

    /// Optional: `defaults write <bundle id> deviceName "Name"` to pick one iPad when you have several.
    private var preferred: String { UserDefaults.standard.string(forKey: "deviceName") ?? "" }

    private func matches(_ device: NSObject) -> Bool {
        preferred.isEmpty || name(of: device).localizedCaseInsensitiveContains(preferred)
    }

    var connectedName: String? {
        devices("connectedDevices").first(where: matches).map { name(of: $0) }
    }

    func toggle(completion: @escaping (Result) -> Void) {
        guard let m = manager else { completion(.unavailable); return }
        let connected = devices("connectedDevices")
        guard let device = connected.first(where: matches) ?? devices("devices").first(where: matches) else {
            completion(.failed("No iPad found. Make sure it's awake and nearby.")); return
        }
        let isConnected = connected.contains { $0 === device || name(of: $0) == name(of: device) }
        let sel = NSSelectorFromString(isConnected ? "disconnectFromDevice:completion:" : "connectToDevice:completion:")
        guard m.responds(to: sel) else { completion(.failed("Sidecar changed in this macOS version.")); return }
        let block: @convention(block) (Error?) -> Void = { error in
            DispatchQueue.main.async {
                if let error { completion(.failed(error.localizedDescription)) }
                else { completion(isConnected ? .disconnected : .connected) }
            }
        }
        _ = m.perform(sel, with: device, with: block)
    }
}

// MARK: - Shortcut

struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier flags

    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey | cmdKey))

    init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }

    /// Requires ⌃, ⌥ or ⌘ so a bare key can't be hijacked.
    init?(event: NSEvent) {
        let f = event.modifierFlags
        var m: UInt32 = 0
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.command) { m |= UInt32(cmdKey) }
        guard m & UInt32(controlKey | optionKey | cmdKey) != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: m)
    }

    private static let keys: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
        39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12",
    ]

    var keyName: String { Self.keys[keyCode] ?? "Key \(keyCode)" }

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName
    }

    /// For showing the shortcut next to the menu item (letters, digits and punctuation only).
    var menuKey: String? { keyName.count == 1 && keyName.first!.isASCII ? keyName.lowercased() : nil }

    var menuMask: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        return f
    }
}

final class HotKey {
    static let shared = HotKey()
    var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false

    func register(_ shortcut: Shortcut?) {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        guard let shortcut else { return }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x5343_4152), id: 1) // 'SCAR'
        RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            let me = Unmanaged<HotKey>.fromOpaque(context!).takeUnretainedValue()
            DispatchQueue.main.async { me.onPress?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), nil)
    }
}

// MARK: - Settings

final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard
    private var syncingLogin = false

    var onMenuBarChange: (() -> Void)?

    @Published var status = ""

    @Published var openAtLogin: Bool {
        didSet { if !syncingLogin && openAtLogin != oldValue { applyLoginItem() } }
    }

    @Published var showInMenuBar: Bool {
        didSet { defaults.set(showInMenuBar, forKey: "showInMenuBar"); onMenuBarChange?() }
    }

    @Published var shortcut: Shortcut? {
        didSet {
            if let s = shortcut {
                defaults.set(Int(s.keyCode), forKey: "shortcutKeyCode")
                defaults.set(Int(s.modifiers), forKey: "shortcutModifiers")
            }
            defaults.set(shortcut == nil, forKey: "shortcutCleared")
            HotKey.shared.register(shortcut)
        }
    }

    private init() {
        defaults.register(defaults: ["showInMenuBar": true])
        showInMenuBar = defaults.bool(forKey: "showInMenuBar")
        openAtLogin = SMAppService.mainApp.status == .enabled
        if defaults.bool(forKey: "shortcutCleared") {
            shortcut = nil
        } else if let code = defaults.object(forKey: "shortcutKeyCode") as? Int {
            let mods = defaults.integer(forKey: "shortcutModifiers")
            shortcut = Shortcut(keyCode: UInt32(code), modifiers: mods != 0 ? UInt32(mods) : Shortcut.standard.modifiers)
        } else {
            shortcut = .standard
        }
    }

    private func applyLoginItem() {
        do {
            if openAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            status = "Couldn't change login item: \(error.localizedDescription)"
        }
        syncingLogin = true
        openAtLogin = SMAppService.mainApp.status == .enabled
        syncingLogin = false
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sidecar Toggle").font(.system(size: 15, weight: .semibold))
                    Text(settings.status).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                row {
                    Text("Open at login")
                    Spacer()
                    Toggle("Open at login", isOn: $settings.openAtLogin).labelsHidden()
                }
                Divider().padding(.leading, 14)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Show in menu bar")
                        Spacer()
                        Toggle("Show in menu bar", isOn: $settings.showInMenuBar).labelsHidden()
                    }
                    if !settings.showInMenuBar {
                        Text("Open Sidecar Toggle from Applications to get back here. Your shortcut still works.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                Divider().padding(.leading, 14)
                row {
                    Text("Toggle shortcut")
                    Spacer()
                    ShortcutRecorder(shortcut: $settings.shortcut)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))

            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .toggleStyle(.switch)
        .font(.system(size: 13))
        .padding(20)
        .frame(width: 400)
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack { content() }.padding(.horizontal, 14).padding(.vertical, 9)
    }
}

struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { recording ? stop() : start() }) {
                Text(recording ? "Type shortcut…" : (shortcut?.display ?? "Record Shortcut"))
                    .foregroundStyle(recording || shortcut == nil ? .secondary : .primary)
                    .frame(minWidth: 110)
            }
            if shortcut != nil && !recording {
                Button(action: { shortcut = nil }) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        HotKey.shared.register(nil) // don't fire the old shortcut while recording
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let bare = event.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty
            if event.keyCode == UInt16(kVK_Escape) && bare { stop(); return nil }
            if event.keyCode == UInt16(kVK_Delete) && bare { shortcut = nil; stop(); return nil }
            if let s = Shortcut(event: event) { shortcut = s; stop() } else { NSSound.beep() }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        HotKey.shared.register(shortcut)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let sidecar = SidecarController()
    private let settings = Settings.shared
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var connectedName: String?
    private var busy = false
    private var lastError: String?
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let event = NSAppleEventManager.shared().currentAppleEvent {
            launchedAtLogin = event.eventID == AEEventID(kAEOpenApplication)
                && event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if offerMoveToApplications() { return }
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = makeMainMenu()
        HotKey.shared.onPress = { [weak self] in self?.toggleSidecar() }
        HotKey.shared.register(settings.shortcut)
        settings.onMenuBarChange = { [weak self] in self?.updateStatusItem() }
        updateStatusItem()
        refresh()
        if !settings.showInMenuBar && !launchedAtLogin { showSettings() }
    }

    /// Opening the app again (Finder, Spotlight, Launchpad) brings up Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    // MARK: Move to Applications

    /// If the app was opened straight from the disk image (or a quarantined Downloads copy that macOS
    /// translocated), offer to copy it into /Applications and relaunch from there. Returns true if
    /// the app is relaunching and this instance should do nothing else.
    private func offerMoveToApplications() -> Bool {
        let source = Bundle.main.bundleURL
        let path = source.path
        let onDiskImage = path.hasPrefix("/Volumes/")
        guard onDiskImage || path.contains("/AppTranslocation/") else { return false }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Sidecar Toggle to Applications?"
        alert.informativeText = onDiskImage
            ? "It's running from the disk image. Move it to Applications so it keeps working after you eject the disk image."
            : "Move it to Applications so it can open at login."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        // Quit any copy that's already running so the new one can take over.
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        where other != NSRunningApplication.current {
            other.terminate()
        }

        let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(source.lastPathComponent)
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.trashItem(at: destination, resultingItemURL: nil)
            }
            try fm.copyItem(at: source, to: destination)
        } catch {
            let failure = NSAlert()
            failure.messageText = "Couldn't move Sidecar Toggle"
            failure.informativeText = "\(error.localizedDescription)\n\nDrag Sidecar Toggle into the Applications folder yourself."
            failure.runModal()
            return false
        }

        // Relaunch from /Applications once this process has quit, ejecting the disk image if we came from one.
        let volume = onDiskImage ? "/" + source.pathComponents.prefix(3).dropFirst().joined(separator: "/") : ""
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = [
            "-c",
            "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; [ -n \"$3\" ] && hdiutil detach \"$3\" -quiet; open \"$2\"",
            "sh", String(ProcessInfo.processInfo.processIdentifier), destination.path, volume,
        ]
        do { try relaunch.run() } catch { return false }
        NSApp.terminate(nil)
        return true
    }

    // MARK: Menu bar

    private func updateStatusItem() {
        if settings.showInMenuBar {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                let menu = NSMenu()
                menu.delegate = self
                menu.autoenablesItems = false
                item.menu = menu
                item.button?.image = Self.glyph
                item.button?.toolTip = "Sidecar Toggle"
                statusItem = item
            }
            statusItem?.button?.appearsDisabled = connectedName == nil
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    /// Template glyph matching the app icon: a display with a stand and an iPad beside it.
    private static let glyph: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: true) { _ in
            NSColor.black.set()
            let display = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 2.5, width: 12.5, height: 9), xRadius: 1.5, yRadius: 1.5)
            let stand = NSBezierPath()
            stand.move(to: NSPoint(x: 7.75, y: 11.5)); stand.line(to: NSPoint(x: 7.75, y: 14.6))
            stand.move(to: NSPoint(x: 5.5, y: 14.6)); stand.line(to: NSPoint(x: 10, y: 14.6))
            let pad = NSBezierPath(roundedRect: NSRect(x: 16, y: 4.8, width: 5, height: 9), xRadius: 1.1, yRadius: 1.1)
            for path in [display, stand, pad] {
                path.lineWidth = 1.4
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }
            pad.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Sidecar Toggle"
        return image
    }()

    private var statusLine: String {
        if busy { return "Working…" }
        if let lastError { return lastError }
        if let connectedName { return "Connected to \(connectedName)" }
        return "iPad not connected"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()

        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let action = NSMenuItem(title: connectedName == nil ? "Connect iPad" : "Disconnect iPad",
                                action: #selector(toggleSidecar), keyEquivalent: "")
        action.target = self
        action.isEnabled = !busy
        if let s = settings.shortcut, let key = s.menuKey {
            action.keyEquivalent = key
            action.keyEquivalentModifierMask = s.menuMask
        }
        menu.addItem(action)

        menu.addItem(.separator())
        let prefs = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(NSMenuItem(title: "Quit Sidecar Toggle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func refresh() {
        connectedName = sidecar.connectedName
        updateStatusItem()
        settings.status = statusLine
    }

    @objc private func toggleSidecar() {
        guard !busy else { return }
        busy = true
        lastError = nil
        settings.status = statusLine
        sidecar.toggle { [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case .connected, .disconnected: self.lastError = nil
            case .unavailable: self.lastError = "Sidecar isn't available on this Mac."
            case .failed(let message): self.lastError = message
            }
            self.refresh()
            // Sidecar reports the new state a moment after the callback.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
        }
    }

    // MARK: Settings window (the Dock icon shows only while it's open)

    @objc private func showSettings() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.styleMask = [.titled, .closable]
            w.title = "Sidecar Toggle"
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        refresh()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let prefs = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        prefs.target = self
        appMenu.addItem(prefs)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        appMenu.addItem(NSMenuItem(title: "Quit Sidecar Toggle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        return main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

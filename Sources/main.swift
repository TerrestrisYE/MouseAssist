// MouseAssist: a menu bar utility that reverses the mouse wheel and turns
// right-button drags into the system's Mission Control and Spaces shortcuts.
//
// Security design (details in SECURITY.md): one session-level event tap that
// only sees right-button and scroll-wheel events, a fixed set of actions
// decided at compile time, no network access, no scripting, no imported
// configuration, no entitlements.

import Cocoa
import ApplicationServices
import ServiceManagement
import os

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MouseAssist", category: "gesture")

// Tags events we post ourselves so the tap lets them through untouched.
private let syntheticMarker: Int64 = 0x4D6F_7573

private enum Direction: String, CaseIterable {
    case up, down, left, right

    var defaultShortcut: SystemShortcut {
        switch self {
        case .up: return .missionControl
        case .down: return .applicationWindows
        case .left: return .spaceLeft
        case .right: return .spaceRight
        }
    }

    var prefKey: String { "gesture.\(rawValue)" }

    var title: String {
        switch self {
        case .up: return NSLocalizedString("Drag Up", comment: "Menu item")
        case .down: return NSLocalizedString("Drag Down", comment: "Menu item")
        case .left: return NSLocalizedString("Drag Left", comment: "Menu item")
        case .right: return NSLocalizedString("Drag Right", comment: "Menu item")
        }
    }
}

private struct KeyCombo {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

// The complete set of system shortcuts a gesture can fire. Preferences only
// pick one of these by name, and each entry carries its macOS default key,
// which is the only key MouseAssist ever sends for it.
private enum SystemShortcut: String, CaseIterable {
    case missionControl, applicationWindows, showDesktop, spaceLeft, spaceRight
    case nextWindow, spotlight, dockHiding
    case desktop1, desktop2, desktop3, desktop4, desktop5, desktop6, desktop7, desktop8, desktop9

    static let desktops: [SystemShortcut] = [.desktop1, .desktop2, .desktop3, .desktop4, .desktop5,
                                             .desktop6, .desktop7, .desktop8, .desktop9]

    enum State { case active, off, rebound }

    // Symbolic hotkey ID, macOS default key, and whether macOS ships it turned on.
    private var definition: (id: Int, keyCode: CGKeyCode, modifiers: CGEventFlags, onByDefault: Bool) {
        switch self {
        case .missionControl: return (32, 126, .maskControl, true)                   // ⌃↑
        case .applicationWindows: return (33, 125, .maskControl, true)               // ⌃↓
        case .showDesktop: return (36, 103, [], true)                                // F11
        case .spaceLeft: return (79, 123, .maskControl, true)                        // ⌃←
        case .spaceRight: return (81, 124, .maskControl, true)                       // ⌃→
        case .nextWindow: return (27, 50, .maskCommand, true)                        // ⌘`
        case .spotlight: return (64, 49, .maskCommand, true)                         // ⌘Space
        case .dockHiding: return (52, 2, [.maskAlternate, .maskCommand], true)       // ⌥⌘D
        case .desktop1: return (118, 18, .maskControl, false)                        // ⌃1
        case .desktop2: return (119, 19, .maskControl, false)                        // ⌃2
        case .desktop3: return (120, 20, .maskControl, false)                        // ⌃3
        case .desktop4: return (121, 21, .maskControl, false)                        // ⌃4
        case .desktop5: return (122, 23, .maskControl, false)                        // ⌃5
        case .desktop6: return (123, 22, .maskControl, false)                        // ⌃6
        case .desktop7: return (124, 26, .maskControl, false)                        // ⌃7
        case .desktop8: return (125, 28, .maskControl, false)                        // ⌃8
        case .desktop9: return (126, 25, .maskControl, false)                        // ⌃9
        }
    }

    /// Whether the shortcut is on and still bound to its macOS default key.
    /// Only this state is read from the system preferences; the key sent is
    /// never taken from them, so a tampered preferences file cannot make
    /// MouseAssist type arbitrary keys.
    var state: State {
        let definition = self.definition
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        let hotkeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any]
        guard let entry = hotkeys?[String(definition.id)] as? [String: Any] else {
            return definition.onByDefault ? .active : .off
        }
        guard (entry["enabled"] as? NSNumber)?.boolValue ?? definition.onByDefault else { return .off }
        // Turned on without key data: macOS uses the default key.
        guard let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [NSNumber],
              parameters.count == 3 else { return .active }
        let modifiers = CGEventFlags(rawValue: parameters[2].uint64Value)
            .intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
        return parameters[1].intValue == Int(definition.keyCode) && modifiers == definition.modifiers
            ? .active : .rebound
    }

    var keyIfActive: KeyCombo? {
        state == .active ? KeyCombo(keyCode: definition.keyCode, flags: definition.modifiers) : nil
    }

    var title: String {
        switch self {
        case .missionControl: return NSLocalizedString("Mission Control", comment: "System shortcut")
        case .applicationWindows: return NSLocalizedString("Application Windows", comment: "System shortcut")
        case .showDesktop: return NSLocalizedString("Show Desktop", comment: "System shortcut")
        case .spaceLeft: return NSLocalizedString("Move Left a Space", comment: "System shortcut")
        case .spaceRight: return NSLocalizedString("Move Right a Space", comment: "System shortcut")
        case .nextWindow: return NSLocalizedString("Move Focus to Next Window", comment: "System shortcut")
        case .spotlight: return NSLocalizedString("Show Spotlight Search", comment: "System shortcut")
        case .dockHiding: return NSLocalizedString("Turn Dock Hiding On/Off", comment: "System shortcut")
        default:
            let number = (SystemShortcut.desktops.firstIndex(of: self) ?? 0) + 1
            return String(format: NSLocalizedString("Switch to Desktop %d", comment: "System shortcut"), number)
        }
    }
}

// Preference value for a direction with no shortcut.
private let noShortcut = "none"

private enum Pref {
    static let reverseScroll = "reverseScroll"
    static let gestures = "gestures"
    static let trigger = "trigger"
    static let gestureDistance = "gestureDistance"
    static let edgeGlow = "edgeGlow"
}

// When a right-button drag turns into a gesture.
private enum GestureTrigger: String, CaseIterable {
    case duringDrag  // as soon as the drag is long enough in a clear direction
    case onRelease   // when the button is released

    var title: String {
        switch self {
        case .duringDrag: return NSLocalizedString("While Dragging", comment: "Menu item")
        case .onRelease: return NSLocalizedString("On Release", comment: "Menu item")
        }
    }
}

// Gesture distances offered in the menu, in points; anything else in the
// preferences falls back to the default.
private let gestureDistances = [20, 30, 40, 60, 80]
private let defaultGestureDistance = 40

// Reads the Space layout through private CoreGraphics calls (the same ones
// yabai and Hammerspoon use). Read-only; yields nil if they ever go away.
private enum SpaceLayout {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let symbols: (MainConnectionID, CopyManagedDisplaySpaces)? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let main = dlsym(handle, "CGSMainConnectionID"),
              let copy = dlsym(handle, "CGSCopyManagedDisplaySpaces") else { return nil }
        return (unsafeBitCast(main, to: MainConnectionID.self),
                unsafeBitCast(copy, to: CopyManagedDisplaySpaces.self))
    }()

    /// Index of the current Space among the desktops and fullscreen apps on `screen`.
    static func position(on screen: NSScreen) -> (index: Int, count: Int)? {
        guard let (mainConnection, copySpaces) = symbols,
              let displays = copySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]] else { return nil }
        // With "Displays have separate Spaces" off there is a single entry for all screens.
        let display = displays.count == 1 ? displays.first : displays.first {
            ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(screen.displayUUID ?? "") == .orderedSame
        }
        guard let display,
              let spaces = display["Spaces"] as? [[String: Any]],
              let current = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int,
              let index = spaces.firstIndex(where: { $0["ManagedSpaceID"] as? Int == current }) else { return nil }
        return (index, spaces.count)
    }
}

private extension NSScreen {
    var displayUUID: String? {
        guard let id = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static var underMouse: NSScreen? {
        let location = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(location, $0.frame, false) } ?? main
    }
}

// A short-lived click-through glow on the screen edge you ran into. It floats
// over fullscreen apps and is visible on every Space.
private final class EdgeGlow {
    private var panel: NSPanel?

    func show(on screen: NSScreen, edge: Direction) {
        let width: CGFloat = 90
        let screenFrame = screen.frame
        let frame = NSRect(x: edge == .left ? screenFrame.minX : screenFrame.maxX - width,
                           y: screenFrame.minY, width: width, height: screenFrame.height)
        let panel = makePanel(frame: frame)

        let gradient = CAGradientLayer()
        gradient.frame = CGRect(origin: .zero, size: frame.size)
        let color = NSColor.controlAccentColor
        gradient.colors = [color.withAlphaComponent(0.65).cgColor, color.withAlphaComponent(0).cgColor]
        gradient.startPoint = CGPoint(x: edge == .left ? 0 : 1, y: 0.5)
        gradient.endPoint = CGPoint(x: edge == .left ? 1 : 0, y: 0.5)
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.addSublayer(gradient)

        present(panel, hold: 0.25)
    }

    private func makePanel(frame: NSRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.alphaValue = 0
        return panel
    }

    private func present(_ panel: NSPanel, hold: TimeInterval) {
        self.panel?.orderOut(nil)
        self.panel = panel
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            guard self?.panel === panel else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }) {
                panel.orderOut(nil)
                if self?.panel === panel { self?.panel = nil }
            }
        }
    }
}

final class InputHook {
    private struct Settings {
        var reverseScroll = true
        var gestures = true
        var trigger = GestureTrigger.duringDrag
        var distance = CGFloat(defaultGestureDistance)
    }

    // Written from the menu on the main thread, read on the tap thread.
    private let settings = OSAllocatedUnfairLock(initialState: Settings())

    var reverseScroll: Bool {
        get { settings.withLock { $0.reverseScroll } }
        set { settings.withLock { $0.reverseScroll = newValue } }
    }

    var gesturesEnabled: Bool {
        get { settings.withLock { $0.gestures } }
        set { settings.withLock { $0.gestures = newValue } }
    }

    fileprivate var trigger: GestureTrigger {
        get { settings.withLock { $0.trigger } }
        set { settings.withLock { $0.trigger = newValue } }
    }

    // Minimum drag distance (points) before a right-button drag counts as a gesture.
    var gestureDistance: CGFloat {
        get { settings.withLock { $0.distance } }
        set { settings.withLock { $0.distance = newValue } }
    }

    // Set once before start(); always called on the main thread.
    // Gets the direction and the timestamp of the event that completed the gesture.
    fileprivate var onGesture: ((Direction, CGEventTimestamp) -> Void)?

    private var tap: CFMachPort?
    // Only touched on the tap thread.
    private var tracking = false
    private var fired = false
    private var origin = CGPoint.zero
    private var pendingDown: CGEvent?

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        // Mouse-only mask: the tap never sees keyboard events.
        let types: [CGEventType] = [.rightMouseDown, .rightMouseDragged, .rightMouseUp, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }
        self.tap = tap

        // The tap runs on its own thread so a busy main thread (menus, overlays)
        // can never stall right clicks and scrolling across the whole system.
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "MouseAssist event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        self.tap = nil
    }

    fileprivate func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == syntheticMarker {
            return Unmanaged.passUnretained(event)
        }
        let current = settings.withLock { $0 }

        switch type {
        case .scrollWheel:
            if current.reverseScroll { reverseIfMouseWheel(event) }

        case .rightMouseDown where current.gestures:
            // Hold the press back until we know whether this is a click or a
            // gesture; otherwise the context menu would open under the drag.
            tracking = true
            fired = false
            origin = event.location
            pendingDown = event.copy()
            return nil

        case .rightMouseDragged where tracking:
            // Fire once, as soon as the drag is long enough and clearly heading
            // one way; the rest of the drag is ignored.
            if current.trigger == .duringDrag, !fired,
               let direction = direction(to: event.location, minimum: current.distance, dominance: 2) {
                fired = true
                pendingDown = nil
                report(direction, at: event.timestamp)
            }
            return nil

        case .rightMouseUp where tracking:
            tracking = false
            if fired { return nil }
            // On release (or a drag that never had a clear direction): the
            // longer axis decides; too short a drag is an ordinary click.
            guard let direction = direction(to: event.location, minimum: current.distance, dominance: 1) else {
                replayClick(proxy: proxy, up: event)
                return nil
            }
            pendingDown = nil
            report(direction, at: event.timestamp)
            return nil

        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    // Trackpad and Magic Mouse scrolls always carry a scroll or momentum phase;
    // a plain wheel never does.
    private func reverseIfMouseWheel(_ event: CGEvent) {
        guard event.getIntegerValueField(.scrollWheelEventScrollPhase) == 0,
              event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 else { return }
        let delta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let fixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let point = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        // Setting DeltaAxis1 rewrites the other two, so it goes first.
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -delta)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixed)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -point)
    }

    /// The drag's direction from the press point, or nil when it is shorter than
    /// `minimum` or its longer axis is under `dominance` times the shorter one.
    private func direction(to location: CGPoint, minimum: CGFloat, dominance: CGFloat) -> Direction? {
        let dx = location.x - origin.x
        let dy = location.y - origin.y
        let major = max(abs(dx), abs(dy))
        guard major >= minimum, major >= dominance * min(abs(dx), abs(dy)) else { return nil }
        // Global display coordinates grow downward, so a negative dy is an upward drag.
        return abs(dx) > abs(dy) ? (dx < 0 ? .left : .right) : (dy < 0 ? .up : .down)
    }

    private func report(_ direction: Direction, at timestamp: CGEventTimestamp) {
        DispatchQueue.main.async { [weak self] in self?.onGesture?(direction, timestamp) }
    }

    private func replayClick(proxy: CGEventTapProxy, up: CGEvent) {
        guard let down = pendingDown, let up = up.copy() else { return }
        pendingDown = nil
        for event in [down, up] {
            event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            event.tapPostEvent(proxy)
        }
    }
}

private func tapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let hook = Unmanaged<InputHook>.fromOpaque(refcon).takeUnretainedValue()
    return hook.handle(proxy: proxy, type: type, event: event)
}

// F1–F12.
private let functionKeyCodes: Set<CGKeyCode> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

private func send(_ combo: KeyCombo) {
    // Arrow and function keys carry extra flags when typed on a real keyboard
    // (fn and numeric pad for arrows, fn for F keys); the system shortcuts
    // only match with them present.
    var flags = combo.flags
    if (123...126).contains(combo.keyCode) { flags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
    if functionKeyCodes.contains(combo.keyCode) { flags.insert(.maskSecondaryFn) }
    let source = CGEventSource(stateID: .hidSystemState)
    for keyDown in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: keyDown) else { continue }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        event.post(tap: .cghidEventTap)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let hook = InputHook()
    private let glow = EdgeGlow()
    private var edgeGlowEnabled = true
    // macOS merges rapid switches into one animation and the Space list only
    // moves on once it ends (up to ~2 s), so trust where the swipes should land
    // until the list catches up or 2.5 s pass after the last switch.
    private var pendingSwitch: (display: String, index: Int, time: Date)?
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem?
    private var trustTimer: Timer?
    private let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second copy would add a second tap and undo the scroll reversal.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty {
            NSApp.terminate(nil)
            return
        }

        defaults.register(defaults: [Pref.reverseScroll: true, Pref.gestures: true, Pref.edgeGlow: true])
        hook.reverseScroll = defaults.bool(forKey: Pref.reverseScroll)
        hook.gesturesEnabled = defaults.bool(forKey: Pref.gestures)
        hook.trigger = GestureTrigger(rawValue: defaults.string(forKey: Pref.trigger) ?? "") ?? .duringDrag
        let distance = defaults.integer(forKey: Pref.gestureDistance)
        hook.gestureDistance = CGFloat(gestureDistances.contains(distance) ? distance : defaultGestureDistance)
        edgeGlowEnabled = defaults.bool(forKey: Pref.edgeGlow)
        hook.onGesture = { [weak self] in self?.handleGesture($0, triggeredAt: $1) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "MouseAssist")

        startWhenTrusted()
        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hook.stop()
    }

    /// The shortcut chosen for `direction`, or nil when it is set to do nothing.
    /// Anything that is not a known name falls back to the direction's default.
    private func shortcut(for direction: Direction) -> SystemShortcut? {
        guard let name = defaults.string(forKey: direction.prefKey) else { return direction.defaultShortcut }
        if name == noShortcut { return nil }
        return SystemShortcut(rawValue: name) ?? direction.defaultShortcut
    }

    private func handleGesture(_ direction: Direction, triggeredAt triggered: CGEventTimestamp) {
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard let shortcut = shortcut(for: direction) else { return }
        guard let combo = shortcut.keyIfActive else {
            log.debug("gesture \(direction.rawValue, privacy: .public): \(shortcut.rawValue, privacy: .public) is off or rebound, nothing sent")
            return
        }
        // Always send the key: the position below is a best guess and only
        // drives the hint, so a wrong guess must never swallow a real switch.
        send(combo)
        let sent = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        log.debug("gesture \(direction.rawValue, privacy: .public) queued \((start &- triggered) / 1_000_000) ms, sent after \((sent &- start) / 1_000_000) ms")

        // The edge glow only applies to moving one Space left or right.
        let edge: Direction
        switch shortcut {
        case .spaceLeft: edge = .left
        case .spaceRight: edge = .right
        default:
            pendingSwitch = nil
            return
        }
        guard let screen = NSScreen.underMouse, let position = SpaceLayout.position(on: screen) else { return }

        let display = screen.displayUUID ?? ""
        if let pending = pendingSwitch,
           pending.display != display || pending.index == position.index
            || Date().timeIntervalSince(pending.time) > 2.5 {
            pendingSwitch = nil
        }
        let index = pendingSwitch.map { min($0.index, position.count - 1) } ?? position.index
        let target = index + (edge == .left ? -1 : 1)
        let atEdge = !(0..<position.count).contains(target)
        log.debug("gesture \(direction.rawValue, privacy: .public) space=\(index + 1)/\(position.count) atEdge=\(atEdge)")
        if !atEdge {
            pendingSwitch = (display, target, Date())
        }

        if atEdge && edgeGlowEnabled {
            glow.show(on: screen, edge: edge)
        }
    }

    // The event tap needs Accessibility access; check again every 2 s until it is granted.
    private func startWhenTrusted() {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt), hook.start() { return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, AXIsProcessTrusted(), self.hook.start() else { return }
            timer.invalidate()
            self.rebuildMenu()
        }
    }

    private var statusText: String {
        if !AXIsProcessTrusted() {
            return hook.isRunning
                ? NSLocalizedString("Accessibility permission was turned off", comment: "Menu status")
                : NSLocalizedString("Waiting for Accessibility permission…", comment: "Menu status")
        }
        return hook.isRunning
            ? NSLocalizedString("Running", comment: "Menu status")
            : NSLocalizedString("Could not start", comment: "Menu status")
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusLine = status
        menu.addItem(item(NSLocalizedString("Open Accessibility Settings…", comment: "Menu item"),
                          #selector(openAccessibilitySettings)))
        menu.addItem(.separator())
        menu.addItem(item(NSLocalizedString("Reverse Mouse Wheel", comment: "Menu item"),
                          #selector(toggleScroll), on: hook.reverseScroll))
        menu.addItem(item(NSLocalizedString("Right-Drag Gestures", comment: "Menu item"),
                          #selector(toggleGestures), on: hook.gesturesEnabled))

        let triggerMenu = NSMenu()
        for trigger in GestureTrigger.allCases {
            let choice = item(trigger.title, #selector(selectTrigger(_:)), on: hook.trigger == trigger)
            choice.representedObject = trigger.rawValue
            triggerMenu.addItem(choice)
        }
        let triggerItem = NSMenuItem(title: NSLocalizedString("Trigger", comment: "Menu item"), action: nil, keyEquivalent: "")
        triggerItem.submenu = triggerMenu
        menu.addItem(triggerItem)

        let distanceMenu = NSMenu()
        for distance in gestureDistances {
            let title = String(format: NSLocalizedString("%d pt", comment: "Gesture distance in points"), distance)
            let choice = item(title, #selector(selectDistance(_:)), on: Int(hook.gestureDistance) == distance)
            choice.representedObject = distance
            distanceMenu.addItem(choice)
        }
        let distanceItem = NSMenuItem(title: NSLocalizedString("Gesture Distance", comment: "Menu item"),
                                      action: nil, keyEquivalent: "")
        distanceItem.submenu = distanceMenu
        menu.addItem(distanceItem)

        for direction in Direction.allCases {
            menu.addItem(shortcutMenuItem(for: direction))
        }
        menu.addItem(item(NSLocalizedString("Edge Glow When No More Spaces", comment: "Menu item"),
                          #selector(toggleEdgeGlow), on: edgeGlowEnabled))
        menu.addItem(item(NSLocalizedString("Launch at Login", comment: "Menu item"),
                          #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(item(NSLocalizedString("Quit MouseAssist", comment: "Menu item"), #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    // "Drag Up ▸" etc.: a radio list of the allowlisted shortcuts, with the
    // desktops grouped in their own submenu.
    private func shortcutMenuItem(for direction: Direction) -> NSMenuItem {
        let selected = shortcut(for: direction)
        let submenu = NSMenu()
        submenu.delegate = self
        let main: [SystemShortcut] = [.missionControl, .applicationWindows, .showDesktop, .spaceLeft, .spaceRight,
                                      .nextWindow, .spotlight, .dockHiding]
        for shortcut in main {
            submenu.addItem(choiceItem(direction, shortcut, selected: selected))
        }

        let desktopMenu = NSMenu()
        desktopMenu.delegate = self
        for shortcut in SystemShortcut.desktops {
            desktopMenu.addItem(choiceItem(direction, shortcut, selected: selected))
        }
        let desktops = NSMenuItem(title: NSLocalizedString("Switch to Desktop", comment: "Menu item"),
                                  action: nil, keyEquivalent: "")
        desktops.submenu = desktopMenu
        desktops.state = selected.map { SystemShortcut.desktops.contains($0) } == true ? .on : .off
        submenu.addItem(desktops)

        submenu.addItem(.separator())
        submenu.addItem(choiceItem(direction, nil, selected: selected))

        let parent = NSMenuItem(title: direction.title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    private func choiceItem(_ direction: Direction, _ shortcut: SystemShortcut?, selected: SystemShortcut?) -> NSMenuItem {
        let title = shortcut.map(choiceTitle) ?? NSLocalizedString("Nothing", comment: "Menu item")
        let choice = item(title, #selector(selectShortcut(_:)), on: shortcut == selected)
        choice.representedObject = [direction.rawValue, shortcut?.rawValue ?? noShortcut]
        return choice
    }

    // Shortcut name plus a note when System Settings has it off or on another key.
    private func choiceTitle(_ shortcut: SystemShortcut) -> String {
        switch shortcut.state {
        case .active: return shortcut.title
        case .off: return shortcut.title + NSLocalizedString(" (off in System Settings)", comment: "Menu item suffix")
        case .rebound: return shortcut.title + NSLocalizedString(" (key changed in System Settings)", comment: "Menu item suffix")
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        statusLine?.title = statusText
        // System Settings may have changed since the menu was built.
        for item in menu.items {
            guard let choice = item.representedObject as? [String], choice.count == 2,
                  let shortcut = SystemShortcut(rawValue: choice[1]) else { continue }
            item.title = choiceTitle(shortcut)
        }
    }

    @objc private func selectTrigger(_ sender: NSMenuItem) {
        guard let trigger = (sender.representedObject as? String).flatMap(GestureTrigger.init(rawValue:)) else { return }
        hook.trigger = trigger
        defaults.set(trigger.rawValue, forKey: Pref.trigger)
        rebuildMenu()
    }

    @objc private func selectDistance(_ sender: NSMenuItem) {
        guard let distance = sender.representedObject as? Int, gestureDistances.contains(distance) else { return }
        hook.gestureDistance = CGFloat(distance)
        defaults.set(distance, forKey: Pref.gestureDistance)
        rebuildMenu()
    }

    @objc private func selectShortcut(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? [String], choice.count == 2,
              let direction = Direction(rawValue: choice[0]),
              choice[1] == noShortcut || SystemShortcut(rawValue: choice[1]) != nil else { return }
        defaults.set(choice[1], forKey: direction.prefKey)
        rebuildMenu()
    }

    private func item(_ title: String, _ action: Selector, on: Bool? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let on { item.state = on ? .on : .off }
        return item
    }

    @objc private func toggleScroll() {
        hook.reverseScroll.toggle()
        defaults.set(hook.reverseScroll, forKey: Pref.reverseScroll)
        rebuildMenu()
    }

    @objc private func toggleGestures() {
        hook.gesturesEnabled.toggle()
        defaults.set(hook.gesturesEnabled, forKey: Pref.gestures)
        rebuildMenu()
    }

    @objc private func toggleEdgeGlow() {
        edgeGlowEnabled.toggle()
        defaults.set(edgeGlowEnabled, forKey: Pref.edgeGlow)
        rebuildMenu()
    }

    // Launching at login is opt-in and goes through SMAppService, so it shows
    // up (and can be removed) under System Settings > General > Login Items.
    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            log.error("login item: \(error.localizedDescription, privacy: .public)")
        }
        rebuildMenu()
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

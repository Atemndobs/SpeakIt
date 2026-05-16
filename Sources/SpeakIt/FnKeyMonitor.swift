import AppKit
import CoreGraphics

/// Captures single taps of the fn / globe (🌐) key via a low-level CGEventTap.
/// The fn key isn't a normal modifier — it doesn't reach Carbon `RegisterEventHotKey`
/// or `KeyboardShortcuts`, so we need to observe `flagsChanged` events directly.
///
/// Permission: Accessibility (already granted). May also prompt for Input Monitoring
/// on first run; allow it in System Settings.
///
/// Recommended macOS pref: System Settings → Keyboard → Press 🌐 key to: Do Nothing
/// (otherwise emoji picker or dictation will fire alongside our handler).
final class FnKeyMonitor {
    var onFnTap: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnDownAt: Date?
    private var otherKeyWhileFnDown = false

    private static let tapDurationLimit: TimeInterval = 0.5

    func start() {
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[FnKey] failed to create event tap — Accessibility/Input Monitoring permission missing?")
            return
        }
        eventTap = tap

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        runLoopSource = src
        print("[FnKey] tap installed")
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        if type == .keyDown {
            if fnDownAt != nil { otherKeyWhileFnDown = true }
            return
        }

        if type == .flagsChanged {
            let isFnDown = event.flags.contains(.maskSecondaryFn)
            if isFnDown && fnDownAt == nil {
                // fn just pressed
                fnDownAt = Date()
                otherKeyWhileFnDown = false
            } else if !isFnDown && fnDownAt != nil {
                // fn just released
                let dur = Date().timeIntervalSince(fnDownAt!)
                fnDownAt = nil
                let wasClean = !otherKeyWhileFnDown
                if wasClean && dur < Self.tapDurationLimit {
                    DispatchQueue.main.async { [weak self] in self?.onFnTap?() }
                }
            }
        }
    }
}

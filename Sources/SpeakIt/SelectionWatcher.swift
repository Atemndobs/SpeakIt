import AppKit
import ApplicationServices

/// Polls the system-wide focused UI element for selected text + its bounds via
/// the Accessibility API. Fires `onChange` when the selection changes.
/// Works in any app that exposes `AXSelectedText`/`AXSelectedTextRange` —
/// native AppKit/Cocoa apps + Safari web content. Most Electron apps don't.
@MainActor
final class SelectionWatcher {
    static let shared = SelectionWatcher()

    struct Selection: Equatable {
        let text: String
        let bounds: CGRect  // AX screen coords: top-left origin, primary screen at (0,0)
    }

    private(set) var current: Selection?
    var onChange: ((Selection?) -> Void)?

    private var timer: Timer?
    private let systemWide = AXUIElementCreateSystemWide()

    func start() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        t.tolerance = 0.05
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let next = readCurrentSelection()
        if next != current {
            current = next
            onChange?(next)
        }
    }

    private func readCurrentSelection() -> Selection? {
        guard let app = copyAttr(systemWide, kAXFocusedApplicationAttribute) else { return nil }
        guard let element = copyAttr(app as! AXUIElement, kAXFocusedUIElementAttribute) else { return nil }
        let el = element as! AXUIElement

        guard let textObj = copyAttr(el, kAXSelectedTextAttribute),
              let text = textObj as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        guard let rangeObj = copyAttr(el, kAXSelectedTextRangeAttribute) else {
            return Selection(text: text, bounds: .zero)
        }
        var cfRange = CFRange()
        AXValueGetValue(rangeObj as! AXValue, .cfRange, &cfRange)

        let rangeAX: AXValue = withUnsafePointer(to: &cfRange) { ptr in
            AXValueCreate(.cfRange, ptr)!
        }

        var boundsRef: AnyObject?
        let err = AXUIElementCopyParameterizedAttributeValue(
            el, kAXBoundsForRangeParameterizedAttribute as CFString, rangeAX, &boundsRef
        )
        guard err == .success, let br = boundsRef else {
            return Selection(text: text, bounds: .zero)
        }
        var rect = CGRect.zero
        AXValueGetValue(br as! AXValue, .cgRect, &rect)
        return Selection(text: text, bounds: rect)
    }

    private func copyAttr(_ element: AXUIElement, _ attr: String) -> AnyObject? {
        var ref: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attr as CFString, &ref)
        return err == .success ? ref : nil
    }
}

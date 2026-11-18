import AppKit
import SwiftUI

/// Own the editor rather than borrowing NSTextField's shared field editor, which
/// is detached on blur and loses the viewport when editing resumes.
struct ComposerTextInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var session: ObjectIdentifier
    var request: Int?
    var enabled: Bool
    var placeholder: String
    var onSubmit: () -> Void
    var onMove: (Int) -> Bool
    var onEscape: () -> Void

    func makeNSView(context: Context) -> EditorScrollView { EditorScrollView() }

    func updateNSView(_ view: EditorScrollView, context: Context) {
        view.onChange = { text = $0 }
        view.onFocus = { focused = $0 }
        view.onSubmit = onSubmit
        view.onMove = onMove
        view.onEscape = onEscape
        view.editor.placeholder = placeholder
        view.update(text: text, session: session, request: request,
                    enabled: enabled, focused: focused)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EditorScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        return CGSize(width: width, height: nsView.height(for: width))
    }

    static func dismantleNSView(_ view: EditorScrollView, coordinator: ()) {
        view.onChange = nil
        view.onFocus = nil
        view.onSubmit = nil
        view.onMove = nil
        view.onEscape = nil
        view.pendingFocus = false
    }

    final class EditorScrollView: NSScrollView, NSTextViewDelegate {
        let editor = Editor()
        var onChange: ((String) -> Void)?
        var onFocus: ((Bool) -> Void)?
        var onSubmit: (() -> Void)?
        var onMove: ((Int) -> Bool)?
        var onEscape: (() -> Void)?
        var pendingFocus = false
        // Sizing proposals must not rewrap or scroll the displayed editor.
        private let measurementStorage = NSTextStorage()
        private let measurementLayout = NSLayoutManager()
        private let measurementContainer = NSTextContainer()
        private var scheduled = false
        private var session: ObjectIdentifier?
        private var request: Int?
        private var enabled = false
        private var focused = false
        private var boundText = ""

        init() {
            super.init(frame: .zero)
            measurementContainer.lineFragmentPadding = 0
            measurementStorage.addLayoutManager(measurementLayout)
            measurementLayout.addTextContainer(measurementContainer)
            drawsBackground = false
            borderType = .noBorder
            hasVerticalScroller = false
            hasHorizontalScroller = false
            editor.isRichText = false
            editor.importsGraphics = false
            editor.allowsUndo = true
            editor.drawsBackground = false
            editor.font = .preferredFont(forTextStyle: .body)
            editor.textColor = .labelColor
            editor.insertionPointColor = .labelColor
            editor.textContainerInset = .zero
            editor.textContainer?.lineFragmentPadding = 0
            editor.isVerticallyResizable = true
            editor.isHorizontallyResizable = false
            editor.autoresizingMask = [.width]
            editor.textContainer?.widthTracksTextView = true
            editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            editor.setAccessibilityLabel("Message")
            editor.delegate = self
            editor.onFocus = { [weak self] in self?.reportFocus() }
            documentView = editor
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func height(for width: CGFloat) -> CGFloat {
            let font = editor.font ?? .preferredFont(forTextStyle: .body)
            let text = NSAttributedString(string: editor.string, attributes: [.font: font])
            if !measurementStorage.isEqual(to: text) { measurementStorage.setAttributedString(text) }
            measurementContainer.containerSize = NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude)
            measurementLayout.ensureLayout(for: measurementContainer)
            let line = measurementLayout.defaultLineHeight(for: font)
            let used = max(measurementLayout.usedRect(for: measurementContainer).maxY,
                           measurementLayout.extraLineFragmentRect.maxY)
            return ceil(min(line * 8, max(line, used)))
        }

        func update(text: String, session: ObjectIdentifier, request: Int?, enabled: Bool, focused: Bool) {
            let changedSession = self.session != session
            // Marked text may differ from the binding until IME composition
            // commits. Only an actual external draft change should replace it.
            if changedSession || (boundText != text && editor.string != text) {
                editor.string = text
                editor.undoManager?.removeAllActions()
                editor.setSelectedRange(NSRange(location: changedSession ? 0 : (text as NSString).length, length: 0))
                if changedSession || text.isEmpty { contentView.scroll(to: .zero) }
                else { editor.scrollRangeToVisible(editor.selectedRange()) }
                editor.needsDisplay = true
                invalidateIntrinsicContentSize()
            }
            boundText = text
            if !focused && self.focused && window?.firstResponder === editor {
                window?.makeFirstResponder(nil)
            }
            if self.request != request || (enabled && !self.enabled) || changedSession {
                pendingFocus = request != nil || focused
            }
            if focused && !self.focused { pendingFocus = true }
            if !enabled { pendingFocus = request != nil || focused }
            self.session = session
            self.request = request
            self.enabled = enabled
            self.focused = focused
            editor.isEditable = enabled
            editor.isSelectable = enabled
            scheduleFocus()
        }

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleFocus() }
        override func layout() { super.layout(); scheduleFocus() }

        private func scheduleFocus() {
            guard pendingFocus, enabled, window != nil, !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                guard self.pendingFocus, self.enabled, let window = self.window,
                      !self.isHiddenOrHasHiddenAncestor else { return }
                self.pendingFocus = false
                if window.firstResponder !== self.editor {
                    self.pendingFocus = !window.makeFirstResponder(self.editor)
                }
            }
        }

        private func reportFocus() {
            // Responder changes can happen inside a SwiftUI update transaction.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let focused = self.window?.firstResponder === self.editor
                self.focused = focused
                self.onFocus?(focused)
            }
        }

        func textDidChange(_ notification: Notification) {
            editor.needsDisplay = true
            invalidateIntrinsicContentSize()
            boundText = editor.string
            onChange?(editor.string)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.intersection([.shift, .option]).isEmpty == false { return false }
                onSubmit?()
                return true
            case #selector(NSResponder.insertTab(_:)):
                window?.selectNextKeyView(nil)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                window?.selectPreviousKeyView(nil)
                return true
            case #selector(NSResponder.moveUp(_:)): return onMove?(-1) ?? false
            case #selector(NSResponder.moveDown(_:)): return onMove?(1) ?? false
            case #selector(NSResponder.cancelOperation(_:)):
                onEscape?()
                return true
            default: return false
            }
        }
    }

    final class Editor: NSTextView {
        var onFocus: (() -> Void)?
        var placeholder = "" { didSet { if oldValue != placeholder { needsDisplay = true } } }

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { onFocus?() }
            return accepted
        }

        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            if accepted { onFocus?() }
            return accepted
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if string.isEmpty {
                (placeholder as NSString).draw(at: .zero, withAttributes: [
                    .font: font ?? NSFont.preferredFont(forTextStyle: .body),
                    .foregroundColor: NSColor.placeholderTextColor
                ])
            }
        }
    }
}

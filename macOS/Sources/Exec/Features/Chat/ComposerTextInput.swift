import AppKit
import SwiftUI

/// Own the editor rather than borrowing NSTextField's shared field editor, which
/// is detached on blur and loses the viewport when editing resumes.
struct ComposerTextInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var session: ObjectIdentifier
    var request: Int?
    var editingState: ComposerEditingState?
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
                    enabled: enabled, focused: focused, editingState: editingState)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EditorScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        return CGSize(width: width, height: nsView.height(for: width))
    }

    static func dismantleNSView(_ view: EditorScrollView, coordinator: ()) {
        view.detach()
        view.onChange = nil
        view.onFocus = nil
        view.onSubmit = nil
        view.onMove = nil
        view.onEscape = nil
        view.pendingFocus = false
    }

    final class EditorScrollView: NSScrollView, NSTextViewDelegate {
        // The caret drawing hooks below use TextKit 1, as does our measurement.
        let editor = Editor(usingTextLayoutManager: false)
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
        private var editingState = ComposerEditingState()
        private var pendingPosition: ComposerEditingState.Position?
        private var updating = false
        private var capturing = false
        private let ownership = UUID()
        private var detached = false

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
            editor.insertionPointColor = .controlAccentColor
            editor.textContainerInset = .zero
            editor.textContainer?.lineFragmentPadding = 0
            editor.isVerticallyResizable = true
            editor.isHorizontallyResizable = false
            editor.autoresizingMask = [.width]
            editor.textContainer?.widthTracksTextView = true
            editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            editor.setAccessibilityLabel("Message")
            editor.delegate = self
            editor.onFocus = { [weak self] in self?.reportFocus($0) }
            documentView = editor
            contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(viewportDidChange),
                                                   name: NSView.boundsDidChangeNotification, object: contentView)
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

        func update(text: String, session: ObjectIdentifier, request: Int?, enabled: Bool, focused: Bool,
                    editingState: ComposerEditingState? = nil) {
            guard !detached else { return }
            let changedSession = self.session != session
            let changedState = editingState.map { $0 !== self.editingState } ?? false
            if changedSession || changedState { capturePosition() }
            if let editingState { self.editingState = editingState }
            let acquiringOwnership = changedSession || changedState || self.editingState.owner == nil
            if acquiringOwnership { self.editingState.owner = ownership }
            guard self.editingState.owner == ownership else { return }
            updating = true
            defer { updating = false }
            if acquiringOwnership {
                let saved = self.editingState.position
                pendingPosition = saved?.session == session && saved?.text == text ? saved : nil
                editor.hasEditingPosition = pendingPosition != nil
                if pendingPosition != nil { needsLayout = true }
            } else if boundText != text && editor.string != text {
                pendingPosition = nil
                self.editingState.position = nil
            }
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
            if !focused && self.focused {
                pendingFocus = false
                if window?.firstResponder === editor { window?.makeFirstResponder(nil) }
            }
            // A request token is an edge, not a standing demand for focus. Keep
            // unconsumed work while disabled, but never replay it just on enable.
            if self.request != request || changedSession {
                pendingFocus = request != nil || focused
            }
            if focused && !self.focused { pendingFocus = true }
            if !enabled && self.enabled && focused { pendingFocus = true }
            self.session = session
            self.request = request
            self.enabled = enabled
            self.focused = focused
            editor.isEditable = enabled
            editor.isSelectable = enabled
            scheduleFocus()
        }

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleFocus() }
        override func layout() {
            super.layout()
            restorePositionIfReady()
            scheduleFocus()
        }

        @objc private func viewportDidChange(_ notification: Notification) { capturePosition() }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !detached, editingState.owner == ownership, !updating else { return }
            pendingPosition = nil
            capturePosition()
        }

        func detach() {
            capturePosition()
            detached = true
            // SwiftUI may keep the original editor after a temporary replacement.
            // Do not leave that survivor blocked by a dismantled owner's token.
            if editingState.owner == ownership { editingState.owner = nil }
            pendingFocus = false
            pendingPosition = nil
            editor.delegate = nil
            editor.onFocus = nil
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: contentView)
        }

        func capturePosition() {
            guard !detached, editingState.owner == ownership,
                  !updating, !capturing, pendingPosition == nil, let session,
                  contentSize.width > 0, contentSize.height > 0,
                  !editor.hasMarkedText(), editor.string == boundText,
                  let layout = editor.layoutManager, let container = editor.textContainer else { return }
            capturing = true
            defer { capturing = false }
            let origin = contentView.bounds.origin
            var character: Int?
            var offset: CGFloat = 0
            if layout.numberOfGlyphs > 0 {
                let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: origin.y), in: container)
                if glyph < layout.numberOfGlyphs {
                    var range = NSRange()
                    let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
                    character = layout.characterIndexForGlyph(at: range.location)
                    offset = origin.y - line.minY
                }
            }
            editingState.position = .init(session: session, text: boundText, selections: editor.selectedRanges,
                                          origin: origin, width: contentSize.width,
                                          topCharacter: character, lineOffset: offset)
        }

        private func restorePositionIfReady() {
            guard !updating, let position = pendingPosition else { return }
            guard !detached, editingState.owner == ownership, position.session == session,
                  position.text == boundText, editor.string == position.text, !editor.hasMarkedText() else {
                pendingPosition = nil
                return
            }
            guard contentSize.width > 0, contentSize.height > 0,
                  let layout = editor.layoutManager, let container = editor.textContainer else { return }
            // Restore after SwiftUI has assigned the real viewport, never while
            // sizing proposals or a zero-sized mount could clamp the offset to 0.
            let wasUpdating = updating
            updating = true
            defer { updating = wasUpdating }
            editor.setFrameSize(NSSize(width: contentSize.width, height: editor.frame.height))
            container.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            let height = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
            editor.setFrameSize(NSSize(width: contentSize.width, height: max(contentSize.height, ceil(height))))
            editor.selectedRanges = position.selections
            var origin = position.origin
            if abs(position.width - contentSize.width) > 0.5,
               let character = position.topCharacter, character < editor.string.utf16.count {
                let glyph = layout.glyphIndexForCharacter(at: character)
                origin.y = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + position.lineOffset
            }
            contentView.scroll(to: origin)
            reflectScrolledClipView(contentView)
            pendingPosition = nil
        }

        private func scheduleFocus() {
            guard !detached, editingState.owner == ownership,
                  pendingFocus, enabled, window != nil, !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                guard !self.detached, self.editingState.owner == self.ownership,
                      self.pendingFocus, self.enabled, let window = self.window,
                      !self.isHiddenOrHasHiddenAncestor else { return }
                self.restorePositionIfReady()
                self.pendingFocus = false
                if window.firstResponder !== self.editor {
                    self.pendingFocus = !window.makeFirstResponder(self.editor)
                }
            }
        }

        private func reportFocus(_ focused: Bool) {
            guard !detached, editingState.owner == ownership else { return }
            // Cancel before the queued focus block can run. A disabled editor's
            // resignation is temporary; preserve its pending prior-focus restore.
            if focused || enabled { pendingFocus = false }
            capturePosition()
            // Responder changes can happen inside a SwiftUI update transaction.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.detached, self.editingState.owner == self.ownership else { return }
                let focused = self.window?.firstResponder === self.editor
                self.focused = focused
                self.onFocus?(focused)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !detached, editingState.owner == ownership, enabled, !updating else { return }
            pendingPosition = nil
            editor.needsDisplay = true
            invalidateIntrinsicContentSize()
            boundText = editor.string
            onChange?(editor.string)
            capturePosition()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !detached, editingState.owner == ownership, enabled, textView === editor else { return true }
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

    class Editor: NSTextView {
        var onFocus: ((Bool) -> Void)?
        var hasEditingPosition = false
        var placeholder = "" { didSet { if oldValue != placeholder { needsDisplay = true } } }
        private static let caretWidth: CGFloat = 2
        private var refocusingClick: NSEvent?

        override func mouseDown(with event: NSEvent) {
            // NSWindow can make us first responder before delivering mouseDown.
            // Match the actual focus-causing event, not the current responder.
            let resumesEditing = refocusingClick === event
            refocusingClick = nil
            if resumesEditing || (hasEditingPosition && window?.firstResponder !== self && isPlainClick(event) &&
                                  window?.makeFirstResponder(self) == true) {
                // A plain refocus click resumes the saved caret/viewport. Track
                // until release or drag, then let NSTextView own drag selection
                // from the original down event, including its normal autoscroll.
                guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                                  until: .distantFuture, inMode: .eventTracking, dequeue: true),
                      next.type == .leftMouseDragged else { return }
                NSApp.postEvent(next, atStart: true)
            }
            super.mouseDown(with: event)
        }

        private func isPlainClick(_ event: NSEvent) -> Bool {
            event.type == .leftMouseDown && event.clickCount == 1 &&
                event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty
        }

        func caretRect(for rect: NSRect) -> NSRect {
            var caret = rect
            caret.size.width = Self.caretWidth
            caret = backingAlignedRect(caret, options: [.alignMinXNearest, .alignMaxXNearest,
                                                       .alignMinYNearest, .alignMaxYNearest])
            // AppKit supplies x = -0.5 at a line start. Without this clamp, the
            // clip view cuts off part of the caret in our zero-inset editor.
            caret.origin.x = max(bounds.minX, caret.minX)
            return caret
        }

        override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
            super.drawInsertionPoint(in: caretRect(for: rect), color: insertionPointColor, turnedOn: flag)
        }

        override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
            // Include the widened stroke when AppKit draws or erases a blink.
            super.setNeedsDisplay(rect.insetBy(dx: -Self.caretWidth, dy: 0), avoidAdditionalLayout: flag)
        }

        override func becomeFirstResponder() -> Bool {
            let hadPosition = hasEditingPosition
            let event = NSApp.currentEvent
            let accepted = super.becomeFirstResponder()
            if accepted {
                if hadPosition, let event, isPlainClick(event), event.window === window,
                   visibleRect.contains(convert(event.locationInWindow, from: nil)) {
                    refocusingClick = event
                }
                hasEditingPosition = true
                onFocus?(true)
            }
            return accepted
        }

        override func resignFirstResponder() -> Bool {
            refocusingClick = nil
            let accepted = super.resignFirstResponder()
            if accepted { onFocus?(false) }
            return accepted
        }

        override func draw(_ dirtyRect: NSRect) {
            // Keep the placeholder underneath the insertion point.
            if string.isEmpty {
                (placeholder as NSString).draw(at: .zero, withAttributes: [
                    .font: font ?? NSFont.preferredFont(forTextStyle: .body),
                    .foregroundColor: NSColor.placeholderTextColor
                ])
            }
            super.draw(dirtyRect)
        }
    }
}

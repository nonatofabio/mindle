import SwiftUI
import AppKit

/// A multi-line text editor backed directly by `NSTextView`. Unlike
/// SwiftUI's `TextEditor`, this view owns its `NSTextView` instance for
/// the lifetime of the SwiftUI view and does not relinquish first
/// responder on parent re-renders.
///
/// Why this exists: the annotation sidebar's `ForEach(store.annotations)`
/// re-renders every card any time any annotation mutates (because
/// `@EnvironmentObject store` fires on any `@Published` change). With a
/// stock `TextEditor` + `@FocusState`, those sibling-driven re-renders
/// can drop first responder mid-keystroke — the user reports "Mac
/// beeps as I type while the agent posts on another annotation." This
/// view's `updateNSView` is idempotent at the AppKit level: it only
/// pushes a change to the text view when state actually differs, and
/// it never resigns first responder on its own.
///
/// Behavior:
/// - Return commits via `onCommit`.
/// - Shift+Return inserts a literal newline (the multi-line case).
/// - Text changes flow back via the `text` binding.
struct FocusStableTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// One-way: when this transitions from false to true, we ask the
    /// window to make our text view the first responder. We never
    /// resign on our own — only the user clicking elsewhere or another
    /// view explicitly stealing focus removes it.
    @Binding var isFocused: Bool
    let font: NSFont
    let textColor: NSColor
    let onCommit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CommittingTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = font
        textView.textColor = textColor
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.onCommit = { [weak coord = context.coordinator] in
            coord?.parent.onCommit()
        }
        // When the user clicks anywhere else (another card, the
        // article, the file browser), AppKit takes first responder
        // away from this text view. Push that back into the binding
        // so updateNSView doesn't try to re-grab focus on the next
        // store change. Without this, isFocused stays stuck at true
        // and any sibling re-render yanks the cursor back to this
        // textbox.
        textView.onResignFocus = { [weak coord = context.coordinator] in
            DispatchQueue.main.async {
                coord?.parent.isFocused = false
            }
        }

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CommittingTextView else { return }
        // Refresh the coordinator's closure-bearing parent so the latest
        // onCommit captures the latest state.
        context.coordinator.parent = self

        // Only mutate the text view's contents if they actually differ.
        // Setting `string` blows away selection and undo state, so
        // skipping the no-op case is what keeps typing smooth across
        // sibling re-renders.
        if textView.string != text {
            textView.string = text
        }
        if textView.font != font {
            textView.font = font
        }
        if textView.textColor != textColor {
            textView.textColor = textColor
        }

        // Push first responder only on the rising edge of isFocused.
        // We never call resignFirstResponder ourselves — AppKit handles
        // resignation via user action, and a spurious SwiftUI re-render
        // setting isFocused=false momentarily must not yank focus.
        if isFocused, let window = textView.window, window.firstResponder !== textView {
            window.makeFirstResponder(textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FocusStableTextEditor
        weak var textView: NSTextView?

        init(parent: FocusStableTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}

/// Read-only, selectable, word-wrapping text label. Backed by
/// `NSTextField` so text-selection actually works inside the annotation
/// sidebar — SwiftUI's `Text(...).textSelection(.enabled)` is unreliable
/// here because the parent `ForEach(store.annotations)` rebuilds every
/// card on any store mutation, dropping the in-flight selection.
/// Same root cause `FocusStableTextEditor` exists for.
struct SelectableText: NSViewRepresentable {
    let text: String
    let font: NSFont
    let textColor: NSColor
    /// 0 = unlimited (full wrap). N>0 clamps height to N line-heights and
    /// truncates with a tail ellipsis.
    var maxLines: Int = 0

    func makeNSView(context: Context) -> SelectableTextHostView {
        let host = SelectableTextHostView()
        host.maxLines = maxLines
        host.configure(text: text, font: font, textColor: textColor)
        return host
    }

    func updateNSView(_ host: SelectableTextHostView, context: Context) {
        if host.maxLines != maxLines {
            host.maxLines = maxLines
        }
        host.configure(text: text, font: font, textColor: textColor)
    }
}

/// AppKit container that owns a non-editable, selectable `NSTextView` and
/// computes a wrap-aware `intrinsicContentSize` so SwiftUI can lay it out
/// as a self-sizing block. We can't use a bare `NSTextView` here because
/// it doesn't expose a wrap-aware intrinsic size — SwiftUI proposes a
/// width that the text view doesn't read, so it lays out at zero height.
/// We can't use the `FocusStableTextEditor` `NSScrollView` wrapping
/// either, because nesting an `NSScrollView` inside SwiftUI's `ScrollView`
/// fights drag gestures with the outer scroller.
final class SelectableTextHostView: NSView {
    private let textView = NSTextView()
    var maxLines: Int = 0 {
        didSet { invalidateIntrinsicContentSize() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isRichText = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(textView)
    }

    func configure(text: String, font: NSFont, textColor: NSColor) {
        if textView.string != text {
            textView.string = text
        }
        if textView.font != font {
            textView.font = font
        }
        if textView.textColor != textColor {
            textView.textColor = textColor
        }
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        textView.frame = bounds
        textView.textContainer?.size = NSSize(
            width: bounds.width,
            height: .greatestFiniteMagnitude
        )
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        guard let lm = textView.layoutManager,
              let tc = textView.textContainer else {
            return super.intrinsicContentSize
        }
        // Force a layout pass at the current width before we read the
        // used rect — without this, the height comes back as zero on the
        // first pass and SwiftUI lays the host at 0pt high.
        tc.size = NSSize(
            width: max(bounds.width, 1),
            height: .greatestFiniteMagnitude
        )
        lm.ensureLayout(for: tc)
        var height = lm.usedRect(for: tc).height
        if maxLines > 0 {
            let lineHeight = lm.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: 12))
            height = min(height, CGFloat(maxLines) * lineHeight)
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(height))
    }
}

/// NSTextView subclass that routes bare Return through a commit
/// closure instead of inserting a newline. Shift+Return inserts a real
/// newline (the multi-line case).
final class CommittingTextView: NSTextView {
    var onCommit: (() -> Void)?
    /// Fired when this text view loses first-responder status. The
    /// SwiftUI binding for isFocused needs to reflect AppKit reality,
    /// otherwise updateNSView keeps trying to re-grab focus.
    var onResignFocus: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn {
            if event.modifierFlags.contains(.shift) {
                insertText("\n", replacementRange: selectedRange())
                return
            }
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign {
            onResignFocus?()
        }
        return didResign
    }
}

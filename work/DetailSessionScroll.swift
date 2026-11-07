import AppKit
import SwiftUI

struct DetailSessionScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            content()
                .background {
                    ThinScrollerInstaller(axis: .vertical, style: .overlay, thumbColor: .white.withAlphaComponent(0.28))
                }
        }
        .scrollIndicators(.automatic)
    }
}

// Use a slim drawing while retaining the native scrollbar's tracking and accessibility.
struct ThinScrollerInstaller: NSViewRepresentable {
    let axis: Axis
    var style: NSScroller.Style = .legacy
    var thumbColor: NSColor = .labelColor.withAlphaComponent(0.32)

    func makeNSView(context: Context) -> InstallerView {
        InstallerView(axis: axis, style: style, thumbColor: thumbColor)
    }

    func updateNSView(_ view: InstallerView, context: Context) {
        view.scheduleInstall()
    }

    final class InstallerView: NSView {
        private let axis: Axis
        private let style: NSScroller.Style
        private let thumbColor: NSColor
        private weak var observedScrollView: NSScrollView?
        private var styleObservation: NSKeyValueObservation?

        init(axis: Axis, style: NSScroller.Style, thumbColor: NSColor) {
            self.axis = axis
            self.style = style
            self.thumbColor = thumbColor
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleInstall()
        }

        func scheduleInstall() {
            DispatchQueue.main.async { [weak self] in self?.install() }
        }

        private func install() {
            guard let scrollView = enclosingScrollView else { return }
            if scrollView !== observedScrollView {
                observedScrollView = scrollView
                styleObservation = scrollView.observe(\.scrollerStyle, options: [.new]) { [weak self] _, change in
                    guard let self, change.newValue != style else { return }
                    DispatchQueue.main.async { [weak self] in self?.install() }
                }
            }
            if scrollView.scrollerStyle != style {
                scrollView.scrollerStyle = style
            }
            let previous = axis == .vertical ? scrollView.verticalScroller : scrollView.horizontalScroller
            if !(previous is ThinScroller) {
                let replacement = ThinScroller(axis: axis, color: thumbColor, frame: previous?.frame)
                if axis == .vertical {
                    scrollView.verticalScroller = replacement
                } else {
                    scrollView.horizontalScroller = replacement
                }
                scrollView.tile()
            }
            if style == .legacy {
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }
}

private final class ThinScroller: NSScroller {
    private let axis: Axis
    private let color: NSColor

    init(axis: Axis, color: NSColor, frame: NSRect?) {
        self.axis = axis
        self.color = color
        let fallbackFrame = axis == .horizontal ? NSRect(x: 0, y: 0, width: 100, height: 12) : .zero
        super.init(frame: frame ?? fallbackFrame)
    }

    required init?(coder: NSCoder) { nil }

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.width > 1, knob.height > 1 else { return }
        let thumb: NSRect
        if axis == .vertical {
            thumb = NSRect(x: knob.maxX - 3, y: knob.minY, width: 3, height: knob.height)
        } else {
            thumb = NSRect(x: knob.minX, y: isFlipped ? knob.maxY - 3 : knob.minY, width: knob.width, height: 3)
        }
        color.setFill()
        NSBezierPath(roundedRect: thumb, xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}

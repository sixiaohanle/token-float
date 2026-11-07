import AppKit
import SwiftUI

struct DetailSessionScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            content()
                .background { DetailScrollerInstaller() }
        }
        .scrollIndicators(.automatic)
    }
}

// Keep native scroll handling and thumb tracking, but overlay the thin thumb
// so the conversation cards can use the full width of the viewport.
private struct DetailScrollerInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> InstallerView { InstallerView() }

    func updateNSView(_ view: InstallerView, context: Context) {
        view.scheduleInstall()
    }

    final class InstallerView: NSView {
        private weak var observedScrollView: NSScrollView?
        private var styleObservation: NSKeyValueObservation?

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
                    guard change.newValue != .overlay else { return }
                    DispatchQueue.main.async { [weak self] in self?.install() }
                }
            }
            if !(scrollView.verticalScroller is DetailScroller) {
                scrollView.verticalScroller = DetailScroller()
            }
            if scrollView.scrollerStyle != .overlay {
                scrollView.scrollerStyle = .overlay
            }
        }
    }
}

private final class DetailScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.height > 1 else { return }
        let thumb = NSRect(x: knob.maxX - 3, y: knob.minY, width: 3, height: knob.height)
        NSColor.white.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}

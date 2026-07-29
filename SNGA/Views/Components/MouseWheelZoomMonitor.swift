import AppKit
import SwiftUI

struct MouseWheelZoomMonitor: NSViewRepresentable {
    var onScroll: @MainActor (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll)
    }

    func makeNSView(context: Context) -> NSView {
        let view = Coordinator.PassthroughView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator {
        final class PassthroughView: NSView {
            override func hitTest(_ point: NSPoint) -> NSView? {
                nil
            }
        }

        var onScroll: @MainActor (CGFloat) -> Void
        private weak var view: NSView?
        private var eventMonitor: Any?

        init(onScroll: @escaping @MainActor (CGFloat) -> Void) {
            self.onScroll = onScroll
        }

        func attach(to view: NSView) {
            self.view = view
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                guard let self,
                      let view = self.view,
                      event.window === view.window,
                      view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else {
                    return event
                }

                let delta = event.scrollingDeltaY
                guard abs(delta) > 0.01 else { return event }
                onScroll(delta)
                return nil
            }
        }

        func stopMonitoring() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

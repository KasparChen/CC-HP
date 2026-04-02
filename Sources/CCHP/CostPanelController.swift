import AppKit
import SwiftUI

/// Manages a floating panel that shows the 14-day cost chart,
/// positioned to the right of the main popover (like CodexBar).
@MainActor
class CostPanelController: ObservableObject {
    @Published var isShown = false

    private var panel: NSPanel?
    private weak var service: UsageService?

    init(service: UsageService) {
        self.service = service
    }

    func toggle(relativeTo popoverWindow: NSWindow?) {
        if isShown {
            close()
        } else {
            show(relativeTo: popoverWindow)
        }
    }

    func show(relativeTo popoverWindow: NSWindow?) {
        guard let service else { return }

        if panel == nil {
            let chartView = CostChartPanel(service: service, controller: self)
            let hosting = NSHostingController(rootView: chartView)

            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 260),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .popUpMenu
            p.hasShadow = true
            p.contentViewController = hosting
            p.isMovableByWindowBackground = false
            panel = p
        }

        // Position to the right of the popover window
        if let popFrame = popoverWindow?.frame, let panel {
            let x = popFrame.maxX + 4
            let y = popFrame.minY
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel?.orderFront(nil)
        isShown = true
    }

    func close() {
        panel?.orderOut(nil)
        isShown = false
    }
}

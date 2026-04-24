import AppKit
import SwiftUI

@MainActor
class CodexTokenPanelController: ObservableObject {
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
            let chartView = CodexTokenChartPanel(service: service, controller: self)
            let hosting = NSHostingController(rootView: chartView)

            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 235),
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

        if let popFrame = popoverWindow?.frame, let panel {
            panel.setFrameOrigin(NSPoint(x: popFrame.maxX + 4, y: popFrame.minY))
        }

        panel?.orderFront(nil)
        isShown = true
    }

    func close() {
        panel?.orderOut(nil)
        isShown = false
    }
}

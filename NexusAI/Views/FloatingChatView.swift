import AppKit
import SwiftUI

/// Owns the floating always-on-top chat window. The window has native
/// minimize/maximize/close controls; minimizing (or closing) it hides the
/// floating surface and re-attaches the conversation back to the main app.
@MainActor
final class FloatingChatController: NSObject, NSWindowDelegate {
    static let shared = FloatingChatController()

    private var panel: NSPanel?
    private(set) var isVisible = false

    /// The floating NSWindow itself (for zoom / window() lookups).
    var window: NSWindow? { panel }

    private override init() {}

    /// Shows the floating chat, or hides it back into the main app if open.
    func toggle(chat: ChatStore, modelStore: ModelStore) {
        if isVisible {
            reattach()
        } else {
            show(chat: chat, modelStore: modelStore)
        }
    }

    func show(chat: ChatStore, modelStore: ModelStore) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            isVisible = true
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                        .fullSizeContentView, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.title = "Nexie — Chat"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .moveToActiveSpace]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        panel.contentViewController = NSHostingController(
            rootView: FloatingChatView(chat: chat, modelStore: modelStore))
        panel.setFrameAutosaveName("NexusAI-FloatingChat")
        panel.center()

        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        isVisible = true
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Hides the floating chat and brings the main app forward.
    func reattach() {
        panel?.orderOut(nil)
        isVisible = false
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Minimize action: re-attach to the main app instead of docking.
    func minimize() {
        reattach()
    }

    /// Maximize action: toggles the panel zoom.
    func zoom() {
        if let panel {
            panel.zoom(nil)
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        reattach()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        reattach()
    }
}

/// Content of the floating chat window. Shared ChatStore keeps it in sync with
/// the main app's active session.
struct FloatingChatView: View {
    @ObservedObject var chat: ChatStore
    @ObservedObject var modelStore: ModelStore

    var body: some View {
        ChatWindowView(chat: chat, modelStore: modelStore, isFloating: true)
            .background(.ultraThinMaterial)
    }
}
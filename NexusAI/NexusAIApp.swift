import SwiftUI
import AppKit

@main
struct NexusAIApp: App {
    @NSApplicationDelegateAdaptor(NexusAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(GlassWindowConfigurator())
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1000, height: 660)
        .commands {
            CommandGroup(after: .textEditing) {
                // ⌘K — focus the chat input
                Button("Focus Chat Input") {
                    NotificationCenter.default.post(name: .nexieFocusInput, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
                // ⌘R — re-run the last query in Research mode
                Button("Re-run Last in Research Mode") {
                    ChatRegistry.shared.active?.rerunLastInResearch()
                }
                .keyboardShortcut("r", modifiers: .command)
                // ⌘D — reveal the most recent generated output
                Button("Reveal Last Output") {
                    NotificationCenter.default.post(name: .nexieRevealOutput, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                // ⌘⇧M — toggle push-to-talk microphone
                Button("Toggle Microphone") {
                    NotificationCenter.default.post(name: .nexieToggleMic, object: nil)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }
    }
}

extension Notification.Name {
    static let nexieFocusInput = Notification.Name("nexie.focusInput")
    static let nexieRevealOutput = Notification.Name("nexie.revealOutput")
    static let nexieToggleMic = Notification.Name("nexie.toggleMic")
}

/// Configures the hosting NSWindow for a vibrant, unified liquid-glass look:
/// transparent titlebar, full-size content, and a material visual effect so the
/// important SwiftUI glass layers show through.
private struct GlassWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let window = v.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = true
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

import SwiftUI
import AppKit

struct ChatView: View {
    @ObservedObject var engine: ChatEngine
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Conversation")
                .font(.title2.bold())

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(engine.messages) { message in
                            LegacyMessageBubble(message: message,
                                                engine: engine,
                                                isLast: message.id == engine.messages.last?.id)
                                .id(message.id)
                        }
                        if engine.isTyping {
                            TypingIndicator()
                                .id("typing")
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 320)
                .onChange(of: engine.messages.count) { _ in
                    if let last = engine.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: engine.isTyping) { typing in
                    if typing { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } }
                }
            }

            HStack(spacing: 10) {
                TextField("Message Nexie…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)

                if !engine.messages.isEmpty {
                    Button("Clear") {
                        engine.clear()
                    }
                }

                Button {
                    send()
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .cardStyle()
    }

    private func send() {
        let text = draft
        draft = ""
        engine.send(text)
    }
}

private struct LegacyMessageBubble: View {
    let message: ChatMessage
    var engine: ChatEngine?
    var isLast = false

    var body: some View {
        HStack {
            if message.role.isUser { Spacer(minLength: 40) }
            Text(message.text)
                .textSelection(.enabled)
                .padding(12)
                .background(message.role.isUser
                            ? Color.accentColor.opacity(0.22)
                            : Color.white.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .opacity(0.35)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.05)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1
                        )
                        .blendMode(.plusLighter)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: 520, alignment: message.role.isUser ? .trailing : .leading)
            if !message.role.isUser { Spacer(minLength: 40) }
        }
        .contextMenu {
            Button {
                copyMessage()
            } label: {
                Label("Copy text", systemImage: "doc.on.doc")
            }
            Divider()
            if let engine, !isLast {
                Button {
                    engine.revert(to: message.id)
                } label: {
                    Label("Revert conversation to here", systemImage: "arrow.uturn.backward")
                }
            }
            if let engine {
                Button(role: .destructive) {
                    engine.deleteMessage(message.id)
                } label: {
                    Label("Delete message", systemImage: "trash")
                }
            }
        }
    }

    private func copyMessage() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.text, forType: .string)
    }
}

private struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .scaleEffect(animating ? 1 : 0.5)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2),
                               value: animating)
            }
        }
        .padding(12)
        .onAppear { animating = true }
    }
}

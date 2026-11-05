import SwiftUI

struct QueuedMessagesView: View {
    @Bindable var store: ChatLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Queued · \(store.current.queuedMessages.count)")
                Spacer()
                if !store.isWorking {
                    Button(action: store.resumeQueuedMessages) {
                        Image(systemName: "play.fill")
                    }
                    .help("Send queued messages").accessibilityLabel("Send queued messages")
                }
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(store.current.queuedMessages) { message in
                        HStack(spacing: 8) {
                            Text(message.text).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            if !message.images.isEmpty {
                                Label("\(message.images.count)", systemImage: "photo")
                                    .accessibilityLabel("\(message.images.count) attached images")
                            }
                            Button { store.current.removeQueuedMessage(message.id) } label: {
                                Image(systemName: "xmark")
                            }
                            .help("Remove queued message").accessibilityLabel("Remove queued message: \(message.text)")
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(height: CGFloat(min(3, store.current.queuedMessages.count)) * 24)
            Divider()
        }
        .font(.caption).foregroundStyle(.secondary).buttonStyle(.plain)
        .disabled(!store.canNavigate)
    }
}

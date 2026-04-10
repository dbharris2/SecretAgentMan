import SwiftUI

struct SessionChatView: View {
    let providerName: String
    let transcript: [CodexTranscriptItem]
    let streaming: String?
    let isThinking: Bool
    let fontScale: Double
    let emptyStateText: String

    @ViewBuilder let pendingCards: () -> AnyView

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if transcript.isEmpty, streaming == nil {
                        Text(emptyStateText)
                            .scaledFont(size: 13)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(transcript) { item in
                            SessionTranscriptBubble(
                                role: item.role,
                                label: SessionPanelTheme.label(for: item.role, providerName: providerName),
                                text: item.text,
                                fontScale: fontScale
                            )
                        }
                    }

                    if let text = streaming, !text.isEmpty {
                        SessionStreamingBubble(providerName: providerName, text: text, fontScale: fontScale)
                    } else if isThinking {
                        SessionThinkingBubble(providerName: providerName)
                    }

                    pendingCards()

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: streaming) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: transcript.count) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: isThinking) { _, thinking in
                if thinking { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

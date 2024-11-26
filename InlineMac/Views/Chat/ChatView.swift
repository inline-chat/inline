import InlineKit
import InlineUI
import SwiftUI
import SwiftUIIntrospect

struct ChatView: View {
  let peerId: Peer

  @EnvironmentObject var data: DataManager

  @StateObject var chatFocus = ChatFocus()
  @StateObject var scroller = ChatScroller()

  @EnvironmentStateObject var fullChat: FullChatViewModel

  var item: SpaceChatItem? {
    fullChat.chatItem
  }

  var title: String {
    item?.title ?? "Chat"
  }

  var subtitle: String {
    "online"
  }

  public init(peerId: Peer) {
    self.peerId = peerId
    _fullChat = EnvironmentStateObject { env in
      // AppKit reversed: false
      // SwiftUI reversed: true
      FullChatViewModel(db: env.appDatabase, peer: peerId, reversed: false)
    }
  }

  @ViewBuilder
  var content: some View {
    GeometryReader { geo in
      //    messageList
      VStack(spacing: 0) {
        MessagesList(width: geo.size.width)

        compose
      }
    }
    .task {
      await fetch()
    }
    .environmentObject(scroller)
    .environmentObject(chatFocus)
    .environmentObject(fullChat)
    .background {
      KeyPressHandler {
        // Return key code
        if $0.keyCode == 36, $0.modifierFlags.contains(.command) {
          if chatFocus.focusedField != .compose {
            chatFocus.focusCompose()
            return nil
          } else {
            // it's focused, so send?
          }
        }

        return $0
      }
    }
  }

  @State var scrollProxy: ScrollViewProxy? = nil

  @ViewBuilder
  var messageList: some View {
    ScrollViewReader { proxy in
      ScrollView(.vertical) {
        if fullChat.fullMessages.isEmpty {
          Text("No messages.")
        } else {
          LazyVStack(pinnedViews: [.sectionFooters]) {
            ForEach(fullChat.messagesInSections) { section in
              Section(footer: DateBadge(date: section.date) {
                scrollTo(section: section, animate: true)
              }.flippedUpsideDown()
              ) {
                ForEach(section.messages, id: \.message.globalId) { fullMessage in
                  // it's last (first), use as scroll for next section by putting it below (above)
                  if section.messages.first == fullMessage {
                    Color.clear
                      .frame(height: 1)
                      .id("section_\(fullChat.getPrevSectionDate(section: section)?.timeIntervalSince1970 ?? 0)")
                  }

                  // Calculate
                  let isFirstOfSenderGroup = deriveMessageProps(fullMessage, section)

                  MessageView(fullMessage: fullMessage, showsSender: isFirstOfSenderGroup)
                    .flippedUpsideDown()
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(fullMessage.message.globalId) // to avoid flashes
                    .onAppear {
                      print("fullChat.fullMessages.first?.message.globalId \(fullChat.fullMessages.first?.message.globalId)")
                    }
                }
              }
            }
          }
          .animation(
            .snappy.speed(2),
            value: fullChat.fullMessages.first?.message.globalId
          )
          .frame(maxWidth: .infinity, minHeight: 0)
          .padding(.horizontal, 12)
        }
      }
      .flippedUpsideDown()
      .introspect(.scrollView, on: .macOS(.v13, .v14, .v15)) { scrollView in
        scrollView.horizontalScrollElasticity = .none
        scrollView.hasHorizontalScroller = false // Add this line
      }
      .scrollBounceBehavior(.basedOnSize)
      .safeAreaInset(edge: .bottom, alignment: .center, spacing: nil) {
        compose
      }
      .onAppear {
        // Configure Scroller
        scrollProxy = proxy
        scroller.hook(
          scrollToMessage: { messageId, animate in
            self.scrollTo(messageId: messageId, animate: animate)
          },
          scrollToBottom: { animated in
            self.scrollToBottom(animated: animated)
          }
        )

        // Focus Compose
        chatFocus.focusCompose()
      }
      // Less than 200 UI gets weird and cuts off at random edges
      .frame(minHeight: 200)
    }
  }

//
//  @ViewBuilder
//  func atBottomThing(_ section: FullChatSection, _ fullMessage: FullMessage) -> some View {
//
//  }

  @ViewBuilder
  var compose: some View {
    Compose(
      chatId: fullChat.chat?.id,
      peerId: peerId,
      topMsgId: fullChat.topMessage?.message.messageId
    )
  }

  var body: some View {
    content
      // Hide default title. No way to achieve this without this for now
      .navigationTitle("")
      //      .navigationSubtitle(subtitle)
      .toolbar {
        ToolbarItem(placement: .navigation) {
          HStack {
            if let user = fullChat.chatItem?.user {
              ChatIcon(peer: .user(user))
            } else if let chat = fullChat.chatItem?.chat {
              ChatIcon(peer: .chat(chat))
            } else {
              // TODO: Handle
            }

            VStack(alignment: .leading) {
              Text(title)
                .font(.headline)
                .padding(.bottom, 0)
              Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.top, 0)
            }
          }
          .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
        }

        // Required to clear up the space for nav title
        ToolbarItem(placement: .principal) {
          Spacer(minLength: 1)
        }

        ToolbarItem(placement: .primaryAction) {
          Button {} label: {
            Label("Info", systemImage: "info.circle")
              .help("Chat Info")
          }
        }
      }
  }

  /// Fetch chat history
  private func fetch() async {
    do {
      let _ = try await data.getChatHistory(peerUserId: nil, peerThreadId: nil, peerId: peerId)
    } catch {
      Log.shared.error("Failed to get chat history", error: error)
    }
  }

  private func deriveMessageProps(_ fullMessage: FullMessage, _ section: FullChatSection) -> Bool {
    let indexOf = section.messages.firstIndex(of: fullMessage) ?? 0
    let sectionCount = section.messages.count
    let prevMessage = indexOf + 1 < sectionCount ? section.messages[indexOf + 1] : nil // + bc reverse
    //    let nextMessage = indexOf > 0 ? section.messages[indexOf - 1] : nil // - bc reverse
    let isFirstOfSenderGroup = (prevMessage?.user?.id ?? -1) != (fullMessage.user?.id ?? -2)

    return isFirstOfSenderGroup
  }

  private func scrollTo(section: FullChatSection, animate: Bool = true) {
    withAnimation(animate ? .easeOut : nil) {
      scrollProxy?.scrollTo("section_\(section.date.timeIntervalSince1970)", anchor: .bottom)
    }
  }

  private func scrollTo(messageId: Int64, animate: Bool = true) {
    guard let globalId = fullChat.getGlobalId(forMessageId: messageId) else {
      return
    }
    scrollTo(globalId: globalId, animate: animate)
  }

  private func scrollTo(globalId: Int64, animate: Bool = true) {
    if animate {
      withAnimation(.easeOut) {
        scrollProxy?.scrollTo(globalId, anchor: .center)
      }
    } else {
      scrollProxy?.scrollTo(globalId, anchor: .center)
    }
  }

  private func scrollToBottom(animated: Bool) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
      if animated {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
          if let id = fullChat.fullMessages.first?.message.globalId {
            scrollTo(globalId: id)
          }
        }
      } else {
        if let id = fullChat.fullMessages.first?.message.globalId {
          scrollTo(globalId: id)
        }
      }
    }
  }
}

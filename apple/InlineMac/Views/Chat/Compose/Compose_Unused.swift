//import AppKit
//import Combine
//import InlineKit
//import SwiftUI
//
//struct Compose: View {
//  var chatId: Int64?
//  var peerId: Peer
//  // Used for optimistic UI
//  var topMsgId: Int64?
//  
//  
//  @EnvironmentObject var data: DataManager
//  @Environment(\.appDatabase) var db
//  @Environment(\.colorScheme) var colorScheme
//  
//  @State private var text: String = ""
//  @State private var event: ComposeTextEditorEvent = .none
//  @State private var editorHeight: CGFloat = 42
//  
//  public static let minHeight: CGFloat = 42
//  var minHeight: CGFloat = Self.minHeight
//  var textViewHorizontalPadding: CGFloat = Theme.messageHorizontalStackSpacing
//
//  var body: some View {
//    HStack(alignment: .bottom, spacing: 0) {
//      attachmentButton
//        .frame(height: minHeight, alignment: .center)
//
//      ComposeTextEditor(
//        text: $text,
//        event: $event,
//        height: $editorHeight,
//        minHeight: minHeight,
//        
//        horizontalPadding: textViewHorizontalPadding,
//        verticalPadding: 4,
//        font: Theme.messageTextFont
//      )
//      .disableAnimations()
//      .onChange(of: event) { newEvent in
//        if newEvent == .none { return }
//        handleEditorEvent(newEvent)
//        event = .none
//      }
//      .onChange(of: text) { newText in
//        // Send compose action for typing
//        if newText.isEmpty {
//          Task { await ComposeActions.shared.stoppedTyping(for: peerId) }
//        } else {
//          Task { await ComposeActions.shared.startedTyping(for: peerId) }
//        }
//      }
//        
//      .background(alignment: .leading) {
//        if text.isEmpty {
//          Text("Write a message")
//            .foregroundStyle(.tertiary)
//            .padding(.leading, textViewHorizontalPadding)
//            .allowsHitTesting(false)
//            .frame(height: editorHeight)
//            .transition(
//              .asymmetric(
//                insertion: .offset(x: 60),
//                removal: .offset(x: 60)
//              )
//              .combined(with: .opacity)
//            )
//        }
//      }
//      .animation(.smoothSnappy.speed(1.5), value: text.isEmpty)
//     
//      sendButton
//        .frame(height: minHeight, alignment: .center)
//        .transition(.scale(scale: 0.8).combined(with: .opacity))
//    }
//    // Matches the chat view background
//    .animation(.easeOut.speed(4), value: canSend)
//    .padding(.horizontal, Theme.messageSidePadding)
//    .background(Color(.textBackgroundColor))
//    .overlay(alignment: .top) {
//      Divider()
//        .frame(height: 1)
//        .offset(y: -1)
//    }
//  }
//  
//  @State var attachmentOverlayOpen = false
//  
//  @ViewBuilder
//  var attachmentButton: some View {
//    Button {
//      // open picker
//      withAnimation(.smoothSnappy) {
//        attachmentOverlayOpen.toggle()
//      }
//    } label: {
//      Image(systemName: "plus")
//        .resizable()
//        .scaledToFit()
//        .foregroundStyle(.tertiary)
//        .fontWeight(.bold)
//    }
//    .buttonStyle(
//      CircleButtonStyle(
//        size: Theme.messageAvatarSize,
//        backgroundColor: .clear,
//        hoveredBackgroundColor: .gray.opacity(0.1)
//      )
//    )
//    .background(alignment: .bottomLeading) {
//      if attachmentOverlayOpen {
//        VStack {
//          Text("Soon you can attach photos and files from here!").padding()
//        }.frame(width: 140, height: 140)
//          .background(.regularMaterial)
//          .zIndex(2)
//          .cornerRadius(12)
//          .offset(x: 10, y: -50)
//          .transition(.scale(scale: 0, anchor: .bottomLeading).combined(with: .opacity))
//      }
//    }
//  }
//  
//  var canSend: Bool {
//    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
//  }
//  
//  @ViewBuilder
//  var sendButton: some View {
//    if canSend {
//      Button {
//        send()
//      } label: {
////        Image(systemName: "paperplane.fill")
////        Image(systemName: "arrowtriangle.up.fill")
//        Image(systemName: "arrow.up")
//          .resizable()
//          .scaledToFit()
//          .foregroundStyle(.white)
//          .fontWeight(.bold)
//      }
//      .buttonStyle(
//        CircleButtonStyle(
//          size: Theme.messageAvatarSize,
//          backgroundColor: .accentColor,
//          hoveredBackgroundColor: .accentColor.opacity(0.8)
//        )
//      )
//    }
//  }
//  
//  private func handleEditorEvent(_ event: ComposeTextEditorEvent) {
//    switch event {
//    case .focus:
//      break
//      
//    case .blur:
//      break
//      
//    case .send:
//      send()
//      
//    case .insertNewline:
//      // Do nothing - let the text view handle the newline
//      break
//      
//    case .dismiss:
//      break
//      
//    default:
//      break
//    }
//  }
//  
//  struct CircleButtonStyle: ButtonStyle {
//    let size: CGFloat
//    let backgroundColor: Color
//    let hoveredBackground: Color
//    
//    @State private var isHovering = false
//    
//    init(
//      size: CGFloat = 32,
//      backgroundColor: Color = .blue,
//      hoveredBackgroundColor: Color = .blue.opacity(0.8)
//    ) {
//      self.size = size
//      self.backgroundColor = backgroundColor
//      self.hoveredBackground = hoveredBackgroundColor
//    }
//    
//    func makeBody(configuration: Configuration) -> some View {
//      configuration.label
//        .padding(8)
//        .frame(width: size, height: size)
//        .background(
//          Circle()
//            .fill(isHovering ? hoveredBackground : backgroundColor)
//        )
//        .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
//        .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
//        .onHover { hovering in
//          withAnimation(.easeInOut(duration: 0.2)) {
//            isHovering = hovering
//          }
//        }
//    }
//  }
// 
//  private func send() {
//    Task {
//      let messageText = text.trimmingCharacters(in: .whitespacesAndNewlines)
//      do {
//        guard !messageText.isEmpty else { return }
//        guard let chatId = chatId else {
//          Log.shared.warning("Chat ID is nil, cannot send message")
//          return
//        }
//        
//        text = ""
//        
//        // Reset editor height after clearing text
//        editorHeight = minHeight
//        
//        let peerUserId: Int64? = if case .user(let id) = peerId { id } else { nil }
//        let peerThreadId: Int64? = if case .thread(let id) = peerId { id } else { nil }
//        
//        let randomId = Int64.random(in: Int64.min ... Int64.max)
//        let message = Message(
//          messageId: -randomId,
//          randomId: randomId,
//          fromId: Auth.shared.getCurrentUserId()!,
//          date: Date(),
//          text: messageText,
//          peerUserId: peerUserId,
//          peerThreadId: peerThreadId,
//          chatId: chatId
//        )
//        
//        try await db.dbWriter.write { db in
//          try message.save(db)
//        }
//        
//        // TODO: Scroll to bottom
//        
//        try await data.sendMessage(
//          chatId: chatId,
//          peerUserId: peerUserId,
//          peerThreadId: peerThreadId,
//          text: messageText,
//          peerId: peerId,
//          randomId: randomId,
//          repliedToMessageId: nil
//        )
//        
//      } catch {
//        Log.shared.error("Failed to send message", error: error)
//        // Optionally show error to user
//      }
//    }
//  }
//}
//

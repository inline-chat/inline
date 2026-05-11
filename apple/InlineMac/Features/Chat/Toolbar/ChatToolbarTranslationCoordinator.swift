import InlineKit
import SwiftUI
import Translation

struct ChatToolbarTranslationButton: View {
  let peer: Peer
  let toolbarState: ChatToolbarState

  var body: some View {
    TranslationToolbarButton(peer: peer) {
      toolbarState.presentTranslationPopover()
    }
    .accessibilityLabel("Translate")
    .help("Translate")
    .onAppear {
      toolbarState.handleAppear(.translate)
    }
    .onDisappear {
      toolbarState.handleDisappear(.translate)
    }
    .modifier(ChatToolbarTranslationPresentations(
      peer: peer,
      toolbarState: toolbarState,
      anchor: .button(.translate),
      listensForPrompt: false
    ))
  }
}

struct ChatToolbarTranslationPresentations: ViewModifier {
  let peer: Peer
  let toolbarState: ChatToolbarState
  let anchor: ChatToolbarState.Anchor
  let listensForPrompt: Bool

  @State private var isTranslationEnabled: Bool

  init(
    peer: Peer,
    toolbarState: ChatToolbarState,
    anchor: ChatToolbarState.Anchor,
    listensForPrompt: Bool
  ) {
    self.peer = peer
    self.toolbarState = toolbarState
    self.anchor = anchor
    self.listensForPrompt = listensForPrompt
    _isTranslationEnabled = State(
      initialValue: listensForPrompt ? TranslationState.shared.isTranslationEnabled(for: peer) : false
    )
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    let presentation = toolbarState.presentation
    let presentedContent = content
      .popover(isPresented: Binding(
        get: { presentation == .translationPopover(anchor) },
        set: { isPresented in
          guard !isPresented, toolbarState.presentation == .translationPopover(anchor) else { return }
          toolbarState.dismissPresentation()
        }
      ), arrowEdge: .bottom) {
        TranslationPopover(
          peer: peer,
          isOptionsSheetPresented: Binding(
            get: { toolbarState.presentation == .translationOptions(anchor) },
            set: { isPresented in
              if isPresented {
                toolbarState.presentTranslationOptions(from: anchor)
              } else if toolbarState.presentation == .translationOptions(anchor) {
                toolbarState.dismissPresentation()
              }
            }
          )
        )
      }
      .popover(isPresented: Binding(
        get: { presentation == .translationPrompt(anchor) },
        set: { isPresented in
          guard !isPresented, toolbarState.presentation == .translationPrompt(anchor) else { return }
          toolbarState.dismissPresentation()
        }
      ), arrowEdge: .bottom) {
        TranslationPrompt(peer: peer) {
          toolbarState.presentTranslationPopover()
        }
      }
      .sheet(isPresented: Binding(
        get: { presentation == .translationOptions(anchor) },
        set: { isPresented in
          guard !isPresented, toolbarState.presentation == .translationOptions(anchor) else { return }
          toolbarState.dismissPresentation()
        }
      )) {
        TranslationOptions(peer: peer)
      }

    if listensForPrompt {
      presentedContent
        .onReceive(TranslationState.shared.subject) { event in
          let (eventPeer, enabled) = event
          guard eventPeer == peer else { return }
          isTranslationEnabled = enabled
        }
        .onReceive(TranslationDetector.shared.needsTranslation) { event in
          guard event.peer == peer, event.needsTranslation else { return }
          guard !isTranslationEnabled else { return }
          toolbarState.presentTranslationPrompt()
        }
    } else {
      presentedContent
    }
  }
}

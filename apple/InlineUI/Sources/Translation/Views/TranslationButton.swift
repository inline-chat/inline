import InlineKit
import SwiftUI

extension Color {
  static var macOSAccent: Color {
    Color("AccentColor")
  }
}

/// Translation button used in iOS nav bar and macOS toolbar
public struct TranslationButton: View {
  /// Peer
  var peer: Peer

  /// Whether to show a popover for toggling translation
  @State var showPopover: Bool = false

  /// Whether to show a small toast-like view indicating translation is available
  @State var showPrompt: Bool = false

  /// Whether to show options sheet
  @State var showOptionsSheet: Bool = false

  @State var isTranslationEnabled: Bool

  public init(peer: Peer) {
    self.peer = peer
    _isTranslationEnabled = State(initialValue: TranslationState.shared.isTranslationEnabled(for: peer))
  }

  /// Button shown in nav bar/toolbar
  @ViewBuilder
  public var button: some View {
    let base = Button {
      pressed()
    } label: {
      // TODO: change the icon from this Apple-copyrighted icon
      Image(systemName: "translate")
    }
    #if os(macOS)
    .font(.system(size: 16))
    .buttonStyle(.automatic)
    #endif

    if isTranslationEnabled {
      base
      #if os(macOS)
      .foregroundStyle(Color.macOSAccent)
      #else
      .foregroundStyle(Color.accentColor)
      #endif
    } else {
      base
        .foregroundStyle(.secondary)
    }
  }

  /// Popover when button is pressed
  @ViewBuilder
  public var popover: some View {
    TranslationPopover(peer: peer, isOptionsSheetPresented: $showOptionsSheet)
      .presentationCompactAdaptation(.popover)
  }

  /// Prompt when translation is available
  @ViewBuilder
  public var prompt: some View {
    TranslationPrompt(peer: peer) {
      showPrompt = false

      #if os(iOS)
      // without this delay, the popover doesn't appear or appears as sheet
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        showPopover = true
      }
      #else
      showPopover = true
      #endif
    }
    .presentationCompactAdaptation(.popover)
  }

  /// Root of the view
  public var body: some View {
    button
      .popover(isPresented: $showPopover, arrowEdge: .bottom) {
        popover
      }

      .overlay(alignment: .bottom) {
        Color.clear.frame(width: 1, height: 1)
          .allowsHitTesting(false)
          .popover(isPresented: $showPrompt, arrowEdge: .bottom) {
            prompt
          }
      }

      .sheet(isPresented: $showOptionsSheet) {
        TranslationOptions(peer: peer)
      }

      /// Listen for translation state changes
      .onReceive(TranslationState.shared.subject) { event in
        let (eventPeer, enabled) = event
        guard eventPeer == peer else { return }
        isTranslationEnabled = enabled
      }

      /// Listen for translation needed prompt
      .onReceive(TranslationDetector.shared.needsTranslation) { event in
        if event.peer == peer,
           event.needsTranslation == true,
           // we don't show prompt if translation is already enabled
           isTranslationEnabled == false
        {
          // show the prompt to let user know translation is available
          showPrompt = true
        }
      }
  }

  private func pressed() {
    showPopover.toggle()

    // Hide automatic prompt
    showPrompt = false
  }
}

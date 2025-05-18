import InlineKit
import SwiftUI

public struct TranslationButton: View {
  let peer: Peer
  @State private var isPopoverPresented = false
  @State private var isTranslationEnabled = false
  @State private var openedAutomatically = false

  public init(peer: Peer) {
    self.peer = peer
    // Initialize state from TranslationState
    _isTranslationEnabled = State(initialValue: TranslationState.shared.isTranslationEnabled(for: peer))
  }

  public var body: some View {
    Button(action: {
      isPopoverPresented.toggle()
    }) {
      Image(systemName: "translate")
        .font(.system(size: 16))
        .foregroundColor(isTranslationEnabled ? .blue : .primary)
    }
    .buttonStyle(.automatic)
    .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
      TranslationPopoverView(
        peer: peer,
        isTranslationEnabled: $isTranslationEnabled,
        isPresented: $isPopoverPresented,
        openedAutomatically: $openedAutomatically
      )
      .frame(width: 190)
      .padding(.horizontal, 8)
      .padding(.vertical, 8)
    }
    .onReceive(TranslationDetector.shared.needsTranslation) { result in
      if result.peer == peer,
         result.needsTranslation == true,
         // don't popover if translation is already enabled
         isTranslationEnabled == false
      {
        // set flag to true when the popover is opened automatically
        openedAutomatically = true
        isPopoverPresented = true
      }
    }
    .onChange(of: isPopoverPresented) { newValue in
      if newValue == false {
        // Reset the flag when the popover is closed
        openedAutomatically = false
      }
    }
  }
}

public struct TranslationPopoverView: View {
  let peer: Peer
  @Binding var isTranslationEnabled: Bool
  @Binding var isPresented: Bool
  @Binding var openedAutomatically: Bool

  public init(
    peer: Peer,
    isTranslationEnabled: Binding<Bool>,
    isPresented: Binding<Bool>,
    openedAutomatically: Binding<Bool>
  ) {
    self.peer = peer
    _isTranslationEnabled = isTranslationEnabled
    _isPresented = isPresented
    _openedAutomatically = openedAutomatically
  }

  var currentLanguageName: String {
    Locale.current.localizedString(forLanguageCode: UserLocale.getCurrentLanguage()) ?? "English"
  }

  public var body: some View {
    VStack(alignment: .center, spacing: 12) {
      if isTranslationEnabled {
        Text("Translated to \(currentLanguageName)")
          .font(.body.weight(.semibold))

        Button("Show Original") {
          TranslationState.shared.setTranslationEnabled(false, for: peer)
          isTranslationEnabled = false
          isPresented = false
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.horizontal)
      } else {
        Text("Translate to \(currentLanguageName)?")
          .font(.title3)

        HStack(spacing: 6) {
          Spacer()

          if openedAutomatically {
            Button("Dismiss") {
              TranslationAlertDismiss.shared.dismissForPeer(peer)
              isPresented = false
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
          }

          Button("Translate") {
            TranslationState.shared.setTranslationEnabled(true, for: peer)
            isTranslationEnabled = true
            isPresented = false
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.regular)

          Spacer()
        }
      }
    }
  }
}

#Preview {
  TranslationButton(peer: .user(id: 1))
}

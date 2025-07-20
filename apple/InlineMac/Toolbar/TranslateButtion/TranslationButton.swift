import InlineKit
import SwiftUI
import Combine

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
        .foregroundColor(isTranslationEnabled ? .accent : .secondary)
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
  @State private var selectedLanguage: Language = Language.getCurrentLanguage()
  @State private var showLanguagePicker = false
  @State private var cancellables = Set<AnyCancellable>()

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
    selectedLanguage.name
  }

  public var body: some View {
    VStack(alignment: .center, spacing: 8) {
      if isTranslationEnabled {
        enabledStateView
      } else {
        disabledStateView
      }
    }
    .onAppear {
      selectedLanguage = Language.getCurrentLanguage()
    }
    .onReceive(NotificationCenter.default.publisher(for: .translationLanguageChanged)) { _ in
      // Update selected language
      selectedLanguage = Language.getCurrentLanguage()
      
      // If translation is currently enabled, refresh translations with new language
      if isTranslationEnabled {
        // Trigger translation refresh by toggling state
        TranslationState.shared.setTranslationEnabled(false, for: peer)
        TranslationState.shared.setTranslationEnabled(true, for: peer)
      }
    }
  }
  
  private var enabledStateView: some View {
    VStack(alignment: .center, spacing: 8) {
      Text("Translated to \(currentLanguageName)")
        .font(.body.weight(.semibold))

      languageChangeButton

      Button("Show Original") {
        TranslationState.shared.setTranslationEnabled(false, for: peer)
        isTranslationEnabled = false
        isPresented = false
      }
      .buttonStyle(.bordered)
      .controlSize(.regular)
      .padding(.horizontal)
    }
  }
  
  private var disabledStateView: some View {
    VStack(alignment: .center, spacing: 8) {
      VStack(alignment: .center, spacing: 4) {
        Text("Translate to \(currentLanguageName)?")
          .font(.title3)

        languageChangeButton
          .font(.caption)
          .foregroundColor(.secondary)
      }

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
        .tint(.accent)

        Spacer()
      }
    }
  }
  
  private var languageChangeButton: some View {
    Button("Change Language") {
      showLanguagePicker = true
    }
    .buttonStyle(.plain)
    .focusEffectDisabled()
    .controlSize(.regular)
    .popover(isPresented: $showLanguagePicker, arrowEdge: .bottom) {
      LanguagePickerView(
        selectedLanguage: $selectedLanguage,
        isPresented: $showLanguagePicker
      )
    }
  }
}

#Preview {
  TranslationButton(peer: .user(id: 1))
}

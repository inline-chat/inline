import InlineKit
import SwiftUI

/// Presented in a popover when the button tapped/clicked to enable/disable/manage translation
public struct TranslationPopover: View {
  var peer: Peer

  @Environment(\.dismiss) private var dismiss

  @State private var selectedLanguage: Language = .getCurrentLanguage()

  @State private var showOptionsSheet = false

  @State private var translationEnabled: Bool

  @Binding private var isOptionsSheetPresented: Bool

  public init(
    peer: Peer,
    isOptionsSheetPresented: Binding<Bool>
  ) {
    self.peer = peer
    _isOptionsSheetPresented = isOptionsSheetPresented
    _translationEnabled = State(initialValue: TranslationState.shared.isTranslationEnabled(for: peer))
  }

  public var body: some View {
    VStack {
      HStack {
        Text(
          translationEnabled
            ?
            "Translated to \(Locale.current.localizedString(forLanguageCode: UserLocale.getCurrentLanguage()) ?? "your language")"
            :
            "Translate this chat to \(Locale.current.localizedString(forLanguageCode: UserLocale.getCurrentLanguage()) ?? "your language")?"
        )
        .foregroundStyle(.primary)
      }

      HStack(spacing: 12) {
        optionsButton
        primaryButton
      }
      .padding(.top, 4)
    }
    .padding()
  }

  /// Primary button: "Translate" or "Show Original"
  @ViewBuilder var primaryButton: some View {
    if translationEnabled {
      Button("Show Original") {
        disableTranslation()
      }
      #if os(macOS)
      .buttonStyle(.bordered)
      .controlSize(.regular)
      .buttonBorderShape(.capsule)
      #endif
    } else {
      Button("Translate") {
        enableTranslation()
      }
      #if os(macOS)
      .buttonStyle(.borderedProminent)
      .controlSize(.regular)
      .buttonBorderShape(.capsule)
      #endif
    }
  }

  /// Primary button: "Translate" or "Show Original"
  @ViewBuilder var optionsButton: some View {
    Button("Options") {
      showOptions()
    }
    .foregroundStyle(.secondary)
    #if os(macOS)
      .buttonStyle(.bordered)
      .controlSize(.regular)
      .buttonBorderShape(.capsule)
      .focusEffectDisabled(true)
    #endif
  }

  // MARK: - Methods

  private func enableTranslation() {
    TranslationState.shared.setTranslationEnabled(true, for: peer)

    // Close after user primary action
    dismiss()
  }

  private func disableTranslation() {
    TranslationState.shared.setTranslationEnabled(false, for: peer)

    // Close after user action
    dismiss()
  }

  private func showOptions() {
    #if os(iOS)
    dismiss()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      isOptionsSheetPresented = true
    }
    #else
    isOptionsSheetPresented = true
    #endif
  }
}

#Preview {
  TranslationPopover(peer: .user(id: 1), isOptionsSheetPresented: .constant(false))
}

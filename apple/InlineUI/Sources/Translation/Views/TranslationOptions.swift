import InlineKit
import SwiftUI

/// Presented in a sheet for changing translation language
public struct TranslationOptions: View {
  @State private var selectedLanguage: Language = .getCurrentLanguage()
  @Environment(\.dismiss) private var dismiss
  
  /// Optional peer to enable translation for when language is changed
  private let peer: Peer?

  public init(peer: Peer? = nil) {
    self.peer = peer
  }

  public var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(Language.getLanguagesForPicker()) { language in
            HStack {
              Text(language.flag)
                .font(.title2)

              HStack(spacing: 6) {
                Text(language.name)
                  .font(.body)
                Text(language.nativeName)
                  .foregroundStyle(.tertiary)
              }

              Spacer()

              if language.code == selectedLanguage.code {
                Image(systemName: "checkmark")
                  .foregroundColor(.blue)
              }
            }
            .contentShape(Rectangle())
            .onTapGesture {
              selectedLanguage = language
              UserLocale.setPreferredTranslationLanguage(language.code)

              // Enable/restart translation for the peer if provided
              if let peer = peer {
                if TranslationState.shared.isTranslationEnabled(for: peer) {
                  // If already enabled, restart translation to apply new language
                  TranslationState.shared.setTranslationEnabled(false, for: peer)
                  TranslationState.shared.setTranslationEnabled(true, for: peer)
                } else {
                  // If not enabled, enable it
                  TranslationState.shared.setTranslationEnabled(true, for: peer)
                }
              }

              dismiss()
            }
          }
        } header: {
          Text("Change Translation Language")
        }
      }
      #if os(macOS)
      .frame(minHeight: 280)
      #endif
      .navigationTitle("Translation")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            dismiss()
          } label: {
            #if os(iOS)
            if #available(iOS 26.0, *) {
              Image(systemName: "xmark")
            } else {
              Text("Done")
            }
            #else
            Text("Done")
            #endif
          }
        }
      }
    }
  }
}

#Preview {
  TranslationOptions()
}

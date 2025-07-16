import SwiftUI

extension Notification.Name {
    public static let translationLanguageChanged = Notification.Name("translationLanguageChanged")
}

public struct LanguagePickerView: View {
    @Binding var selectedLanguage: Language
    @Binding var isPresented: Bool
    
    private let languages = Language.getLanguagesForPicker()
    
    public init(selectedLanguage: Binding<Language>, isPresented: Binding<Bool>) {
        self._selectedLanguage = selectedLanguage
        self._isPresented = isPresented
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Select Translation Language")
                .font(.headline)
                .foregroundColor(.primary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(languages) { language in
                        LanguagePickerItem(
                            language: language,
                            isSelected: selectedLanguage.code == language.code,
                            isSystemLanguage: false,
                            onTap: {
                                let previousLanguage = selectedLanguage
                                selectedLanguage = language
                                UserLocale.setPreferredTranslationLanguage(language.code)
                                
                                // If language changed, notify translation system to refresh
                                if previousLanguage.code != language.code {
                                    NotificationCenter.default.post(
                                        name: .translationLanguageChanged,
                                        object: nil,
                                        userInfo: [
                                            "previousLanguage": previousLanguage.code,
                                            "newLanguage": language.code
                                        ]
                                    )
                                }
                                
                                isPresented = false
                            }
                        )
                    }
                }
            }
            .padding(.bottom, 4)
        }
        .frame(width: 240)
        .frame(maxHeight: 280)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)
    }
}

struct LanguagePickerItem: View {
    let language: Language
    let isSelected: Bool
    let isSystemLanguage: Bool
    let onTap: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // Show gear icon for system language, flag for others
                if isSystemLanguage {
                    Image(systemName: "gear")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                } else {
                    Text(language.flag)
                        .font(.system(size: 16))
                        .frame(width: 20, height: 20)
                }
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(language.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                    
                    if !isSystemLanguage {
                        Text(language.nativeName)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
        .padding(.horizontal, 4)
    }
    
    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.12)
        } else if isHovered {
            return Color(.controlAccentColor).opacity(0.06)
        } else {
            return Color.clear
        }
    }
}

#Preview {
    LanguagePickerView(
        selectedLanguage: .constant(.english),
        isPresented: .constant(true)
    )
}

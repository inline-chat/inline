import Foundation

enum ComposeVoiceInputMode: String {
  case voiceMessage
  case transcribe

  private static let preferenceKey = "compose.voiceInputMode"

  static var selected: Self {
    get {
      return Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .voiceMessage
    }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey) }
  }

  var title: String { self == .voiceMessage ? "Voice Message" : "Transcribe" }
  var symbol: String { self == .voiceMessage ? "mic.fill" : "waveform" }
  var actionTitle: String { self == .voiceMessage ? "Record voice message" : "Start dictation" }
}

import Auth
import InlineProtocol
import Logger

public extension InlineProtocol.UpdateComposeAction.ComposeAction {
  func toApiComposeAction() -> ApiComposeAction {
    switch self {
      case .typing:
        .typing
      case .uploadingDocument:
        .uploadingDocument
      case .uploadingPhoto:
        .uploadingPhoto
      case .uploadingVideo:
        .uploadingVideo
      case .recordingVoice:
        .recordingVoice
      default:
        .typing
    }
  }
}

public extension ApiComposeAction {
  func toProtocolComposeAction() -> InlineProtocol.UpdateComposeAction.ComposeAction {
    switch self {
      case .typing:
        .typing
      case .uploadingDocument:
        .uploadingDocument
      case .uploadingPhoto:
        .uploadingPhoto
      case .uploadingVideo:
        .uploadingVideo
      case .recordingVoice:
        .recordingVoice
    }
  }
}

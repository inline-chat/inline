import InlineProtocol
import InlineRTC

/// Presentation effects supplied by the host app. Room authority, media
/// admission, and transport ownership remain in the shared Grid service.
@MainActor
public struct GridPlatformEffects {
  public enum Sound {
    case join
    case leave
    case connected
  }

  public var playSound: ((Sound) -> Void)?
  public var displayIDUnderPointer: (() -> UInt32?)?
  public var updateScreenShareOutline: ((InlineRTCScreenCaptureSource?) -> Void)?
  public var closeScreenShares: (() -> Void)?
  public var openScreenShare: ((InlineProtocol.User, InlineRTCScreenShare, GridRoomService) -> Void)?
  public var presentScreenShareChange: ((GridScreenShareChange, GridRoomService) -> Void)?
  public var showError: ((String) -> Void)?

  public init() {}
}

public struct GridScreenShareChange {
  public let spaceID: Int64
  public let roomID: Int64
  public let user: InlineProtocol.User
  public let participantIdentity: String
  public let started: Bool
}

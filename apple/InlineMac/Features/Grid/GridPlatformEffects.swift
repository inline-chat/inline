import AppKit
import CoreGraphics
import InlineGrid
import InlineKit

extension GridPlatformEffects {
  @MainActor
  static var macOS: GridPlatformEffects {
    var effects = GridPlatformEffects()
    effects.playSound = { sound in
      switch sound {
        case .join: GridSoundEffects.shared.play(.join)
        case .leave: GridSoundEffects.shared.play(.leave)
        case .connected: GridSoundEffects.shared.play(.connected)
      }
    }
    effects.displayIDUnderPointer = {
      let mouseLocation = NSEvent.mouseLocation
      guard let screen = NSScreen.screens.first(where: {
        NSMouseInRect(mouseLocation, $0.frame, false)
      }),
        let screenNumber = screen.deviceDescription[
          NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber
      else { return CGMainDisplayID() }
      return screenNumber.uint32Value
    }
    effects.updateScreenShareOutline = { source in
      if let source {
        GridScreenShareOutlineCoordinator.shared.show(for: source)
      } else {
        GridScreenShareOutlineCoordinator.shared.hide()
      }
    }
    effects.closeScreenShares = { GridScreenShareWindowCoordinator.shared.closeAll() }
    effects.openScreenShare = { user, share, service in
      GridScreenShareWindowCoordinator.shared.open(user: user, share: share, store: service)
    }
    effects.presentScreenShareChange = { notice, service in
      let displayName = InlineKit.User(from: notice.user).displayName
      if notice.started {
        ToastCenter.shared.showSuccess(
          "\(displayName) started sharing their screen",
          actionTitle: "View"
        ) { [weak service] in
          guard let service,
                let grid = service.grid(spaceID: notice.spaceID),
                let room = grid.rooms.first(where: { $0.id == notice.roomID }),
                let avatar = room.avatars.first(where: { $0.user.id == notice.user.id })
          else { return }
          service.openScreenShare(for: avatar)
        }
      } else {
        ToastCenter.shared.showInfo("\(displayName) stopped sharing their screen")
      }
      Task {
        await MacNotifications.shared.showGridScreenShareNotification(
          displayName: displayName,
          started: notice.started,
          spaceID: notice.spaceID,
          roomID: notice.roomID,
          userID: notice.user.id,
          participantIdentity: notice.participantIdentity
        )
      }
    }
    effects.showError = { ToastCenter.shared.showError($0) }
    return effects
  }
}

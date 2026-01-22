#if SPARKLE
import Combine
import Foundation

final class UpdateViewModel: ObservableObject {
  @Published var state: UpdateState = .idle
}

enum UpdateState {
  case idle
  case permission(UpdatePermissionState)
  case checking(UpdateCheckingState)
  case updateAvailable(UpdateAvailableState)
  case downloading(UpdateDownloadingState)
  case extracting(UpdateExtractingState)
  case readyToInstall(UpdateReadyState)
  case installing(UpdateInstallingState)
  case notFound(UpdateNotFoundState)
  case error(UpdateErrorState)

  var isIdle: Bool {
    if case .idle = self { return true }
    return false
  }
}

struct UpdatePermissionState {
  let message: String
  let allow: () -> Void
  let deny: () -> Void
}

struct UpdateCheckingState {
  let cancel: () -> Void
}

struct UpdateAvailableState {
  let version: String
  let build: String?
  let contentLength: Int64?
  let install: () -> Void
  let later: () -> Void
}

struct UpdateDownloadingState {
  let cancel: () -> Void
  let expectedLength: Int64?
  let receivedLength: Int64
}

struct UpdateExtractingState {
  let progress: Double
}

struct UpdateReadyState {
  let install: () -> Void
  let later: () -> Void
}

struct UpdateInstallingState {
  let retryTerminatingApplication: () -> Void
  let dismiss: () -> Void
}

struct UpdateNotFoundState {
  let acknowledgement: () -> Void
}

struct UpdateErrorState {
  let message: String
  let retry: () -> Void
  let dismiss: () -> Void
}
#endif

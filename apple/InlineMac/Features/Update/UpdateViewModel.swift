#if SPARKLE
import Combine
import Foundation

@MainActor
final class UpdateViewModel: ObservableObject {
  @Published var state: UpdateState = .idle
}

@MainActor
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

@MainActor
struct UpdatePermissionState {
  let message: String
  let allow: () -> Void
  let deny: () -> Void
}

@MainActor
struct UpdateCheckingState {
  let cancel: () -> Void
}

@MainActor
struct UpdateAvailableState {
  let version: String
  let build: String?
  let contentLength: Int64?
  let install: () -> Void
  let later: () -> Void
}

@MainActor
struct UpdateDownloadingState {
  let cancel: () -> Void
  let expectedLength: Int64?
  let receivedLength: Int64
}

@MainActor
struct UpdateExtractingState {
  let progress: Double
}

@MainActor
struct UpdateReadyState {
  let install: () -> Void
  let later: () -> Void
}

@MainActor
struct UpdateInstallingState {
  let retryTerminatingApplication: () -> Void
  let dismiss: () -> Void
}

@MainActor
struct UpdateNotFoundState {
  let acknowledgement: () -> Void
}

@MainActor
struct UpdateErrorState {
  let message: String
  let retry: () -> Void
  let dismiss: () -> Void
}
#endif

import Auth
import Foundation
import Kingfisher
import Logger
import Observation

/// Classifications deliberately contain no URL, request, image or user data.
enum AvatarImageFailure: String, Error, PrivacySafeErrorCategoryProviding {
  case cancelled, network, httpTransient, httpPermanent, decode, cache, source

  var privacySafeErrorCategory: String { "avatar_load:\(rawValue)" }
  var canRetry: Bool { self == .network || self == .httpTransient }

  init(_ error: KingfisherError) {
    if error.isTaskCancelled { self = .cancelled; return }
    switch error {
    case .responseError(reason: .URLSessionError(let underlying)):
      let error = underlying as NSError
      self = error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled ? .cancelled : .network
    case .responseError(reason: .invalidHTTPStatusCode(let response)):
      self = [408, 429, 500, 502, 503, 504].contains(response.statusCode) ? .httpTransient : .httpPermanent
    case .processorError: self = .decode
    case .cacheError: self = .cache
    case .imageSettingError(reason: .alternativeSourcesExhausted(let errors)):
      self = errors.last.map { AvatarImageFailure($0.error) } ?? .source
    default: self = .source
    }
  }
}

/// Replaces KFImage's binder for avatars. Kingfisher still owns decoding, coalescing and caching.
/// Unlike KFImage in Kingfisher 7, this owner always retains the current request after a retry.
@Observable
@MainActor
final class AvatarImageLoader {
  private(set) var image: KFCrossPlatformImage?
  private(set) var failure: AvatarImageFailure?
  @ObservationIgnored private var source: UserAvatarImageSource?
  @ObservationIgnored private var generation: UInt = 0
  @ObservationIgnored private var active = false
  @ObservationIgnored private var usedRetry = false
  @ObservationIgnored private var account: AuthAccountMutationToken?
  @ObservationIgnored private var admitted = false
  @ObservationIgnored private var download: DownloadTask?
  @ObservationIgnored private var retryTask: Task<Void, Never>?
  @ObservationIgnored private let manager: KingfisherManager
  @ObservationIgnored private let accountIsCurrent: (@MainActor () -> Bool)?
  @ObservationIgnored private let delay: Duration

  init(manager: KingfisherManager = .shared, delay: Duration = .milliseconds(500),
       accountIsCurrent: (@MainActor () -> Bool)? = nil) {
    self.manager = manager
    self.delay = delay
    self.accountIsCurrent = accountIsCurrent
  }

  var currentAccount: AuthAccountMutationToken? { isCurrent ? account : nil }

  var isCurrent: Bool {
    guard active else { return false }
    if let accountIsCurrent { return accountIsCurrent() }
    guard let account else { return Auth.shared.getCurrentUserId() == nil }
    do {
      try Auth.shared.handle.validateAccountMutation(account)
      return true
    } catch { return false }
  }

  func start(source: UserAvatarImageSource, size: CGFloat, scale: CGFloat,
             onSuccess: @escaping @MainActor (URL) -> Void = { _ in }) {
    if self.source != source {
      cancel()
      image = nil
      failure = nil
      usedRetry = false
      self.source = source
    }
    guard !active else { return }
    if !admitted {
      account = try? Auth.shared.handle.beginAccountMutation()
      admitted = true
    }
    active = true
    guard isCurrent, image == nil else { return }
    load(source: source, url: source.url, size: size, scale: scale,
         generation: generation, onSuccess: onSuccess)
  }

  func cancel() {
    active = false
    generation &+= 1
    retryTask?.cancel()
    retryTask = nil
    download?.cancel()
    download = nil
  }

  // Kingfisher 7 does not declare its result Sendable. Image delivery stays on the main actor.
  private struct Delivery: @unchecked Sendable {
    let result: Result<RetrieveImageResult, KingfisherError>
  }

  private func load(source: UserAvatarImageSource, url: URL, size: CGFloat, scale: CGFloat,
                    generation: UInt, onSuccess: @escaping @MainActor (URL) -> Void) {
    guard self.generation == generation, isCurrent else { return }
    download = manager.retrieveImage(
      with: KF.ImageResource(downloadURL: url, cacheKey: source.cacheKey),
      options: [.processor(DownsamplingImageProcessor(size: CGSize(width: max(size, 1), height: max(size, 1)))),
                .scaleFactor(scale), .cacheOriginalImage, .loadDiskFileSynchronously,
                .callbackQueue(.mainCurrentOrAsync)],
      completionHandler: { [weak self] result in
        let delivery = Delivery(result: result)
        MainActor.assumeIsolated {
          guard let self, self.generation == generation, self.isCurrent else { return }
          self.download = nil
          switch delivery.result {
          case .success(let value):
            self.image = value.image
            self.failure = nil
            onSuccess(url)
          case .failure(let error):
            // A local provider cannot be cancelled, so gate fallback after its completion too.
            let failure = AvatarImageFailure(error)
            if failure != .cancelled, url.isFileURL, let remote = source.fallbackURL {
              self.load(source: source, url: remote, size: size, scale: scale,
                        generation: generation, onSuccess: onSuccess)
            } else if failure.canRetry, !self.usedRetry {
              self.usedRetry = true
              self.retryTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: self?.delay ?? .zero) } catch { return }
                guard let self, self.generation == generation, self.isCurrent else { return }
                self.retryTask = nil
                self.load(source: source, url: url, size: size, scale: scale,
                          generation: generation, onSuccess: onSuccess)
              }
            } else if failure != .cancelled {
              self.failure = failure
              // Never pass the original Kingfisher error, which can contain signed URLs.
              Log.shared.error("Avatar image load failed", error: failure)
            }
          }
        }
      }
    )
  }
}

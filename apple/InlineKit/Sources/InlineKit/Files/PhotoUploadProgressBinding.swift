@preconcurrency import Combine
import Foundation

/// Follows one photo's upload progress for a view on the main thread.
@MainActor
public final class PhotoUploadProgressBinding {
  private var photoLocalId: Int64?
  private var bindingTask: Task<Void, Never>?
  private var cancellable: AnyCancellable?

  public init() {}

  public func bind(
    photoLocalId: Int64,
    onChange: @escaping @MainActor (UploadProgressSnapshot) -> Void
  ) {
    guard self.photoLocalId != photoLocalId else { return }

    clear()
    self.photoLocalId = photoLocalId

    bindingTask = Task { [weak self] in
      let publisher = await FileUploader.shared.photoProgressPublisher(photoLocalId: photoLocalId)
      guard let self, !Task.isCancelled, self.photoLocalId == photoLocalId else { return }

      self.bindingTask = nil
      self.cancellable = publisher
        .receive(on: DispatchQueue.main)
        .sink { progress in
          MainActor.assumeIsolated {
            onChange(progress)
          }
        }
    }
  }

  public func clear() {
    bindingTask?.cancel()
    bindingTask = nil
    cancellable?.cancel()
    cancellable = nil
    photoLocalId = nil
  }
}

extension FullMessage {
  /// An outgoing photo still on its way up, which reserves room for a bar under its bubble.
  public var showsPhotoUploadProgress: Bool {
    guard let photoInfo else { return false }
    return message.isSticker != true
      && message.status == .sending
      && photoInfo.bestPhotoSize()?.cdnUrl == nil
  }
}

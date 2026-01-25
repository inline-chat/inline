import Combine
import GRDB
import InlineKit
import SwiftUI

public struct SpaceAvatar: View {
  let space: Space
  let size: CGFloat

  @StateObject private var viewModel: SpaceAvatarViewModel

  public init(space: Space, size: CGFloat = 32) {
    self.space = space
    self.size = size
    _viewModel = StateObject(wrappedValue: SpaceAvatarViewModel(spaceId: space.id, photoId: space.photoId))
  }

  public var body: some View {
    ZStack {
      if let photoInfo = viewModel.photoInfo {
        SpacePhotoView(photoInfo: photoInfo, size: size)
      } else {
        InitialsCircle(
          name: space.name,
          size: size
          // symbol: "person.2.fill"
        )
      }
    }
    .onChange(of: space.photoId) { newValue in
      viewModel.update(spaceId: space.id, photoId: newValue)
    }
    .onChange(of: space.id) { _ in
      viewModel.update(spaceId: space.id, photoId: space.photoId)
    }
  }
}

private struct SpacePhotoView: View {
  let photoInfo: PhotoInfo
  let size: CGFloat

  var body: some View {
    PlatformPhotoRepresentable(photoInfo: photoInfo)
      .frame(width: size, height: size)
      .clipShape(RoundedRectangle(cornerRadius: size / 3, style: .continuous))
  }
}

#if os(iOS)
private struct PlatformPhotoRepresentable: UIViewRepresentable {
  let photoInfo: PhotoInfo

  func makeUIView(context: Context) -> PlatformPhotoView {
    let view = PlatformPhotoView()
    view.photoContentMode = .aspectFill
    view.setPhoto(photoInfo)
    return view
  }

  func updateUIView(_ uiView: PlatformPhotoView, context: Context) {
    uiView.photoContentMode = .aspectFill
    uiView.setPhoto(photoInfo)
  }
}
#else
private struct PlatformPhotoRepresentable: NSViewRepresentable {
  let photoInfo: PhotoInfo

  func makeNSView(context: Context) -> PlatformPhotoView {
    let view = PlatformPhotoView()
    view.photoContentMode = .aspectFill
    view.setPhoto(photoInfo)
    return view
  }

  func updateNSView(_ nsView: PlatformPhotoView, context: Context) {
    nsView.photoContentMode = .aspectFill
    nsView.setPhoto(photoInfo)
  }
}
#endif

private final class SpaceAvatarViewModel: ObservableObject {
  @Published var photoInfo: PhotoInfo?

  private let db: AppDatabase
  private var photoId: Int64?
  private var spaceId: Int64?
  private var cancellable: AnyCancellable?

  init(spaceId: Int64, photoId: Int64?, db: AppDatabase = .shared) {
    self.db = db
    update(spaceId: spaceId, photoId: photoId)
  }

  func update(spaceId: Int64, photoId: Int64?) {
    guard photoId != self.photoId || spaceId != self.spaceId else { return }
    self.spaceId = spaceId
    self.photoId = photoId

    cancellable?.cancel()

    guard let photoId else {
      photoInfo = nil
      return
    }

    cancellable = ValueObservation
      .tracking { db in
        try Photo
          .filter(Photo.Columns.photoId == photoId)
          .including(all: Photo.sizes.forKey(PhotoInfo.CodingKeys.sizes))
          .asRequest(of: PhotoInfo.self)
          .fetchOne(db)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { _ in },
        receiveValue: { [weak self] photoInfo in
          self?.photoInfo = photoInfo
        }
      )
  }
}

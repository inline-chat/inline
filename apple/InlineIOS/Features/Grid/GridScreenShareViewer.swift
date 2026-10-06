import InlineGrid
import InlineRTC
import SwiftUI
import UIKit

struct GridScreenShareSelection: Identifiable {
  let mediaSessionIdentity: String
  let participantIdentity: String
  let publicationID: String
  let displayName: String
  var id: String { "\(mediaSessionIdentity):\(publicationID)" }
}

struct GridScreenShareViewer: View {
  let store: GridRoomService
  let selection: GridScreenShareSelection
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase

  private var selectedShare: InlineRTCScreenShare? {
    guard store.mediaSessionIdentity == selection.mediaSessionIdentity,
          let share = store.screenShare(publicationID: selection.publicationID),
          share.participantIdentity == selection.participantIdentity
    else { return nil }
    return share
  }

  var body: some View {
    NavigationStack {
      GridVideoRenderer(screenShare: selectedShare, isVideoEnabled: scenePhase == .active)
        .background(.black)
        .navigationTitle(selection.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button("Done", systemImage: "xmark") { dismiss() }
              .labelStyle(.iconOnly)
              .accessibilityLabel("Close shared screen")
          }
        }
        .safeAreaInset(edge: .bottom) {
          if let call = store.currentCall {
            GridCurrentRoomControls(store: store, spaceID: call.spaceID)
              .padding(.vertical, 8)
              .background(.regularMaterial)
          }
        }
        .onChange(of: selectedShare?.publicationID) { _, publicationID in
          if publicationID == nil { dismiss() }
        }
        .onAppear {
          if selectedShare == nil { dismiss() }
        }
        .onChange(of: store.mediaSessionIdentity) { _, identity in
          if identity != selection.mediaSessionIdentity { dismiss() }
        }
    }
  }
}

private struct GridVideoRenderer: UIViewRepresentable {
  let screenShare: InlineRTCScreenShare?
  let isVideoEnabled: Bool

  func makeUIView(context: Context) -> GridVideoScrollView {
    let view = GridVideoScrollView()
    view.videoView.screenShare = screenShare
    view.videoView.isVideoEnabled = isVideoEnabled
    return view
  }

  func updateUIView(_ uiView: GridVideoScrollView, context: Context) {
    if uiView.videoView.screenShare?.publicationID != screenShare?.publicationID {
      uiView.setZoomScale(1, animated: false)
    }
    uiView.videoView.screenShare = screenShare
    uiView.videoView.isVideoEnabled = isVideoEnabled
  }

  static func dismantleUIView(_ uiView: GridVideoScrollView, coordinator: ()) {
    uiView.videoView.isVideoEnabled = false
    uiView.videoView.screenShare = nil
  }
}

private final class GridVideoScrollView: UIScrollView, UIScrollViewDelegate {
  let videoView = InlineRTCVideoView(frame: .zero)
  private var viewportSize: CGSize = .zero

  init() {
    super.init(frame: .zero)
    delegate = self
    minimumZoomScale = 1
    maximumZoomScale = 4
    showsHorizontalScrollIndicator = false
    showsVerticalScrollIndicator = false
    contentInsetAdjustmentBehavior = .never
    backgroundColor = .black
    addSubview(videoView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard bounds.size != viewportSize else { return }
    viewportSize = bounds.size
    setZoomScale(1, animated: false)
    videoView.frame = CGRect(origin: .zero, size: viewportSize)
    contentSize = viewportSize
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? {
    videoView
  }
}

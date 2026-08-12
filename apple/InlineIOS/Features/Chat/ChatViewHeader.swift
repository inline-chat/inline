import QuartzCore
import SwiftUI
import UIKit

struct ChatViewHeader: View {
  @Binding private var navBarHeight: CGFloat

  init(navBarHeight: Binding<CGFloat>) {
    _navBarHeight = navBarHeight
  }

  let theme = ThemeManager.shared.selected
  var body: some View {
//    LinearGradient(
//      gradient: Gradient(colors: [
//        Color(theme.backgroundColor).opacity(1),
//        Color(theme.backgroundColor).opacity(0.0),
//      ]),
//      startPoint: .top,
//      endPoint: .bottom
//    )
    VariableBlurView(maxBlurRadius: 6)
      /// +28 to enhance the variant blur effect; it needs more space to cover the full navigation bar background
//    .frame(height: 60)  was 38
      .frame(height: navBarHeight + 12) // was 38
      .contentShape(Rectangle())
      .background(
        LinearGradient(
          gradient: Gradient(colors: [
            Color(.systemBackground).opacity(1),
            Color(.systemBackground).opacity(0.0),
          ]),
          startPoint: .top,
          endPoint: .bottom
        )
      )

      // Spacer()
      .ignoresSafeArea(.all)
      .allowsHitTesting(false)
  }
}

@available(iOS 27.0, *)
struct ChatToolbarBackgroundExperimentView: View {
  @Binding private var navBarHeight: CGFloat

  init(navBarHeight: Binding<CGFloat>) {
    _navBarHeight = navBarHeight
  }

  var body: some View {
    ChatToolbarBackgroundMaterial()
      .frame(height: navBarHeight)
      .contentShape(Rectangle())
      .ignoresSafeArea(.all)
      .allowsHitTesting(false)
  }
}

@available(iOS 27.0, *)
private struct ChatToolbarBackgroundMaterial: UIViewRepresentable {
  func makeUIView(context _: Context) -> ChatToolbarBackgroundMaterialView {
    ChatToolbarBackgroundMaterialView()
  }

  func updateUIView(_ uiView: ChatToolbarBackgroundMaterialView, context _: Context) {
    uiView.updateAppearance()
  }
}

@available(iOS 27.0, *)
private final class ChatToolbarBackgroundMaterialView: UIView {
  private enum Material {
    static let blurRadius: CGFloat = 5
    static let tintAlpha: CGFloat = 0.85
    static let separatorAlpha: CGFloat = 0.05
  }

  private let backdropView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
  private let tintLayer = CALayer()
  private let separatorLayer = CALayer()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    let scale = window?.screen.scale ?? traitCollection.displayScale
    let separatorHeight = 1 / max(scale, 1)

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    backdropView.frame = bounds
    tintLayer.frame = bounds
    separatorLayer.frame = CGRect(
      x: bounds.minX,
      y: bounds.maxY - separatorHeight,
      width: bounds.width,
      height: separatorHeight
    )
    tintLayer.contentsScale = scale
    separatorLayer.contentsScale = scale
    CATransaction.commit()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    configureBackdropFilter()
    updateBackdropScale()
    updateAppearance()
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    configureBackdropFilter()
    updateBackdropScale()
    updateAppearance()
  }

  func updateAppearance() {
    let tintColor = ThemeManager.shared.selected.backgroundColor
      .resolvedColor(with: traitCollection)
      .withAlphaComponent(Material.tintAlpha)

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    tintLayer.backgroundColor = tintColor.cgColor
    separatorLayer.backgroundColor = UIColor.separator
      .resolvedColor(with: traitCollection)
      .withAlphaComponent(Material.separatorAlpha)
      .cgColor
    CATransaction.commit()
  }

  private func setupView() {
    isOpaque = false
    clipsToBounds = true
    isUserInteractionEnabled = false

    backdropView.isUserInteractionEnabled = false
    addSubview(backdropView)
    configureBackdropFilter()

    layer.addSublayer(tintLayer)
    layer.addSublayer(separatorLayer)
    updateAppearance()
  }

  private func configureBackdropFilter() {
    guard let filter = ChatToolbarBackgroundPrivateFilter.gaussianBlur(radius: Material.blurRadius) else {
      return
    }

    backdropView.subviews.first?.layer.filters = [filter]
    for subview in backdropView.subviews.dropFirst() {
      subview.alpha = 0
    }
  }

  private func updateBackdropScale() {
    let scale = window?.screen.scale ?? traitCollection.displayScale
    guard let backdropLayer = backdropView.subviews.first?.layer else { return }
    backdropLayer.contentsScale = scale
    if backdropLayer.responds(to: NSSelectorFromString("setScale:")) {
      backdropLayer.setValue(scale, forKey: "scale")
    }
  }
}

@available(iOS 27.0, *)
private enum ChatToolbarBackgroundPrivateFilter {
  static func gaussianBlur(radius: CGFloat) -> NSObject? {
    guard let filterClass = NSClassFromString(String("retliFAC".reversed())) as? NSObject.Type else {
      return nil
    }

    let selector = NSSelectorFromString(String(":epyThtiWretlif".reversed()))
    guard let filter = filterClass.perform(selector, with: "gaussianBlur")?.takeUnretainedValue() as? NSObject else {
      return nil
    }

    filter.setValue(radius, forKey: "inputRadius")
    filter.setValue(true, forKey: "inputNormalizeEdges")
    return filter
  }
}

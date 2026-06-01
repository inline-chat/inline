import AppKit
import SwiftUI

@MainActor
final class OverlayManager: ObservableObject, ToastPresenting {
  enum ToastStyle: Equatable {
    case info
    case success
    case error
  }

  struct ToastModel: Equatable {
    struct Countdown {
      let startDate: Date
      let duration: TimeInterval
    }

    let id = UUID()
    let message: String
    let style: ToastStyle
    let showsSpinner: Bool
    let countdown: Countdown?
    let actionTitle: String?
    let action: (@MainActor () -> Void)?
    let placement: ToastPlacement

    static func == (lhs: ToastModel, rhs: ToastModel) -> Bool {
      lhs.id == rhs.id
    }
  }

  private weak var toastContainerView: NSView?
  private var toastHostingView: NSHostingView<ToastBannerView>?
  private var toastPlacementConstraint: NSLayoutConstraint?
  private var toastPlacement = ToastPlacement.standard
  @Published private(set) var toastModel: ToastModel?
  private var dismissTask: Task<Void, Never>?

  func attachToast(to containerView: NSView) {
    if toastContainerView !== containerView, toastHostingView != nil {
      dismissToast()
    }
    toastContainerView = containerView
    ToastCenter.shared.presenter = self
  }

  func showLoading(
    _ message: String,
    actionTitle: String?,
    action: (@MainActor () -> Void)?,
    placement: ToastPlacement
  ) {
    showToast(
      message: message,
      style: .info,
      showsSpinner: true,
      countdown: nil,
      actionTitle: actionTitle,
      action: action,
      placement: placement,
      autoDismissAfter: nil
    )
  }

  func showUndoCountdown(
    _ message: String,
    duration: TimeInterval,
    actionTitle: String,
    action: @escaping @MainActor () -> Void,
    placement: ToastPlacement
  ) {
    showToast(
      message: message,
      style: .info,
      showsSpinner: false,
      countdown: ToastModel.Countdown(startDate: Date(), duration: duration),
      actionTitle: actionTitle,
      action: action,
      placement: placement,
      autoDismissAfter: nil
    )
  }

  func showInfo(_ message: String, placement: ToastPlacement) {
    showToast(
      message: message,
      style: .info,
      showsSpinner: false,
      countdown: nil,
      actionTitle: nil,
      action: nil,
      placement: placement,
      autoDismissAfter: 1.4
    )
  }

  func showSuccess(
    _ message: String,
    actionTitle: String?,
    action: (@MainActor () -> Void)?,
    placement: ToastPlacement
  ) {
    showToast(
      message: message,
      style: .success,
      showsSpinner: false,
      countdown: nil,
      actionTitle: actionTitle,
      action: action,
      placement: placement,
      autoDismissAfter: actionTitle == nil ? 1.4 : 6.0
    )
  }

  func showError(_ message: String, placement: ToastPlacement) {
    showToast(
      message: message,
      style: .error,
      showsSpinner: false,
      countdown: nil,
      actionTitle: nil,
      action: nil,
      placement: placement,
      autoDismissAfter: 2.0
    )
  }

  func dismissToast() {
    dismissTask?.cancel()
    dismissTask = nil
    let placement = toastModel?.placement ?? toastPlacement
    toastModel = nil

    guard let host = toastHostingView else { return }
    let placementConstraint = toastPlacementConstraint
    let containerView = host.superview
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.2
      host.animator().alphaValue = 0
      placementConstraint?.animator().constant = placement.hiddenConstant
      containerView?.animator().layoutSubtreeIfNeeded()
    } completionHandler: { [weak self, weak host] in
      Task { @MainActor in
        guard self?.toastModel == nil else { return }
        host?.removeFromSuperview()
        self?.toastHostingView = nil
        self?.toastPlacementConstraint = nil
      }
    }
  }

  private func showToast(
    message: String,
    style: ToastStyle,
    showsSpinner: Bool,
    countdown: ToastModel.Countdown?,
    actionTitle: String?,
    action: (@MainActor () -> Void)?,
    placement: ToastPlacement,
    autoDismissAfter seconds: TimeInterval?
  ) {
    dismissTask?.cancel()
    dismissTask = nil

    let model = ToastModel(
      message: message,
      style: style,
      showsSpinner: showsSpinner,
      countdown: countdown,
      actionTitle: actionTitle,
      action: action,
      placement: placement
    )
    toastModel = model

    if let seconds {
      dismissTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        await MainActor.run {
          guard let self else { return }
          if self.toastModel?.id == model.id {
            self.dismissToast()
          }
        }
      }
    }

    guard let containerView = toastContainerView else { return }

    let banner = ToastBannerView(
      model: model,
      dismiss: { [weak self] in
        self?.dismissToast()
      }
    )

    let host: NSHostingView<ToastBannerView>
    if let existing = toastHostingView {
      host = existing
      host.rootView = banner
      if toastPlacement != placement || toastPlacementConstraint == nil {
        setToastPlacement(placement, host: host, containerView: containerView, hidden: true)
      }
    } else {
      host = NSHostingView(rootView: banner)
      host.translatesAutoresizingMaskIntoConstraints = false
      host.alphaValue = 0
      toastHostingView = host
      containerView.addSubview(host)

      NSLayoutConstraint.activate([
        host.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
        host.widthAnchor.constraint(lessThanOrEqualTo: containerView.widthAnchor, constant: -36),
      ])
      setToastPlacement(placement, host: host, containerView: containerView, hidden: true)
      containerView.layoutSubtreeIfNeeded()
    }

    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.2
      host.animator().alphaValue = 1
      toastPlacementConstraint?.animator().constant = placement.visibleConstant
      containerView.animator().layoutSubtreeIfNeeded()
    }
  }

  private func setToastPlacement(_ placement: ToastPlacement, host: NSView, containerView: NSView, hidden: Bool) {
    toastPlacementConstraint?.isActive = false

    let constraint = placement.constraint(host: host, containerView: containerView)
    constraint.constant = hidden ? placement.hiddenConstant : placement.visibleConstant
    constraint.isActive = true

    toastPlacement = placement
    toastPlacementConstraint = constraint
  }

  func showError(title: String? = nil, message: String, error: Error? = nil) {
    // TODO: Show error to user via a toast or something
    let alert = NSAlert()
    alert.messageText = title ?? "Something went wrong"
    alert.messageText = message
    alert.informativeText = error?.localizedDescription ?? ""
    alert.alertStyle = .critical
    alert.addButton(withTitle: "OK")

    alert.runModal() // shows alert modally
  }
}

private extension ToastPlacement {
  var visibleConstant: CGFloat {
    switch self {
      case let .topCenter(offset):
        offset
      case let .bottomCenter(offset):
        -offset
    }
  }

  var hiddenConstant: CGFloat {
    switch self {
      case let .topCenter(offset):
        max(8, offset - 10)
      case .bottomCenter:
        36
    }
  }

  func constraint(host: NSView, containerView: NSView) -> NSLayoutConstraint {
    switch self {
      case .topCenter:
        host.topAnchor.constraint(equalTo: containerView.topAnchor)
      case .bottomCenter:
        host.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
    }
  }
}

extension View {
  @ViewBuilder
  func toastOverlayHost(_ overlay: OverlayManager?) -> some View {
    if let overlay {
      modifier(ToastOverlayModifier(overlay: overlay))
    } else {
      self
    }
  }
}

private struct ToastOverlayModifier: ViewModifier {
  @ObservedObject var overlay: OverlayManager

  func body(content: Content) -> some View {
    content
      .overlay {
        if let toast = overlay.toastModel {
          ToastBannerView(
            model: toast,
            dismiss: {
              overlay.dismissToast()
            }
          )
          .padding(.horizontal, 18)
          .toastPlacement(toast.placement)
          .transition(.opacity)
          .zIndex(10)
        }
      }
      .animation(.easeOut(duration: 0.2), value: overlay.toastModel?.id)
  }
}

private extension View {
  @ViewBuilder
  func toastPlacement(_ placement: ToastPlacement) -> some View {
    switch placement {
      case let .topCenter(offset):
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .padding(.top, offset)
      case let .bottomCenter(offset):
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
          .padding(.bottom, offset)
    }
  }
}

private struct ToastBannerView: View {
  let model: OverlayManager.ToastModel
  let dismiss: @MainActor () -> Void

  @Environment(\.colorScheme) private var colorScheme

  private var isInteractive: Bool {
    model.actionTitle == nil || model.action == nil
  }

  private var tint: Color {
    let opacity = 0.08
    return colorScheme == .dark ? Color.black.opacity(opacity) : Color.white.opacity(opacity)
  }

  private var iconName: String {
    switch model.style {
      case .info:
        "info.circle.fill"
      case .success:
        "checkmark.circle.fill"
      case .error:
        "exclamationmark.triangle.fill"
    }
  }

  private var iconColor: Color {
    switch model.style {
      case .info:
        .secondary
      case .success:
        .green
      case .error:
        .red
    }
  }

  @ViewBuilder
  private var leadingIndicator: some View {
    if let countdown = model.countdown {
      CountdownToastIndicator(countdown: countdown)
    } else {
      if model.showsSpinner {
        ProgressView()
          .controlSize(.small)
      }

      Image(systemName: iconName)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(iconColor)
    }
  }

  @ViewBuilder
  private var toastContent: some View {
    let shape = Capsule()
    let content = HStack(spacing: 10) {
      leadingIndicator

      Text(model.message)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.primary)
        .lineLimit(2)

      if let title = model.actionTitle, let action = model.action {
        if #available(macOS 26.0, *) {
          Button(title) {
            action()
            dismiss()
          }
          .buttonStyle(.glass)
          .controlSize(.small)
        } else {
          Button(title) {
            action()
            dismiss()
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }
    }
    .padding(.vertical, 10)
    .padding(.horizontal, 12)
    if #available(macOS 26.0, *) {
      content
        .glassEffect(.regular.interactive(isInteractive), in: shape)
        .shadow(color: .black.opacity(0.10), radius: 10, x: 0, y: 6)
        .contentShape(shape)
        .if(model.actionTitle == nil || model.action == nil) { view in
          view.onTapGesture {
            dismiss()
          }
        }
    } else {
      content
        .background(shape.fill(tint))
        .shadow(color: .black.opacity(0.10), radius: 10, x: 0, y: 6)
        .contentShape(shape)
        .if(model.actionTitle == nil || model.action == nil) { view in
          view.onTapGesture {
            dismiss()
          }
        }
    }
  }

  var body: some View {
    toastContent
  }
}

private struct CountdownToastIndicator: View {
  let countdown: OverlayManager.ToastModel.Countdown

  private var duration: TimeInterval {
    max(countdown.duration, 0.1)
  }

  var body: some View {
    TimelineView(.periodic(from: countdown.startDate, by: 0.1)) { context in
      let elapsed = max(0, context.date.timeIntervalSince(countdown.startDate))
      let remaining = max(0, duration - elapsed)
      let seconds = max(0, Int(ceil(remaining)))
      let progress = max(0, min(1, remaining / duration))

      ZStack {
        Circle()
          .stroke(Color.secondary.opacity(0.22), lineWidth: 2)
        Circle()
          .trim(from: 0, to: progress)
          .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
          .rotationEffect(.degrees(-90))
        Text("\(seconds)")
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      .frame(width: 24, height: 24)
      .accessibilityLabel("\(seconds) seconds remaining")
    }
  }
}

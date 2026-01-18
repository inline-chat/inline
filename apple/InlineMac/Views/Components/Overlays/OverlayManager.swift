import SwiftUI

@MainActor
final class OverlayManager: ObservableObject, ToastPresenting {
  enum ToastStyle: Equatable {
    case info
    case success
    case error
  }

  struct ToastModel: Equatable {
    let id = UUID()
    let message: String
    let style: ToastStyle
    let showsSpinner: Bool
    let actionTitle: String?
    let action: (@MainActor () -> Void)?

    static func == (lhs: ToastModel, rhs: ToastModel) -> Bool {
      lhs.id == rhs.id
    }
  }

  private weak var toastContainerView: NSView?
  private var toastHostingView: NSHostingView<ToastBannerView>?
  private var toastTopConstraint: NSLayoutConstraint?
  private var toastModel: ToastModel?
  private var dismissTask: Task<Void, Never>?
  private let toastVisibleTopOffset: CGFloat = 18
  private let toastHiddenTopOffset: CGFloat = 8

  func attachToast(to containerView: NSView) {
    toastContainerView = containerView
    ToastCenter.shared.presenter = self
  }

  func showLoading(_ message: String) {
    showToast(
      message: message,
      style: .info,
      showsSpinner: true,
      actionTitle: nil,
      action: nil,
      autoDismissAfter: nil
    )
  }

  func showSuccess(_ message: String, actionTitle: String?, action: (@MainActor () -> Void)?) {
    showToast(
      message: message,
      style: .success,
      showsSpinner: false,
      actionTitle: actionTitle,
      action: action,
      autoDismissAfter: actionTitle == nil ? 1.4 : 6.0
    )
  }

  func showError(_ message: String) {
    showToast(
      message: message,
      style: .error,
      showsSpinner: false,
      actionTitle: nil,
      action: nil,
      autoDismissAfter: 2.0
    )
  }

  func dismissToast() {
    dismissTask?.cancel()
    dismissTask = nil
    toastModel = nil

    guard let host = toastHostingView else { return }
    let topConstraint = toastTopConstraint
    let containerView = host.superview
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.2
      host.animator().alphaValue = 0
      topConstraint?.animator().constant = toastHiddenTopOffset
      containerView?.animator().layoutSubtreeIfNeeded()
    } completionHandler: { [weak self] in
      host.removeFromSuperview()
      self?.toastHostingView = nil
      self?.toastTopConstraint = nil
    }
  }

  private func showToast(
    message: String,
    style: ToastStyle,
    showsSpinner: Bool,
    actionTitle: String?,
    action: (@MainActor () -> Void)?,
    autoDismissAfter seconds: TimeInterval?
  ) {
    dismissTask?.cancel()
    dismissTask = nil

    let model = ToastModel(
      message: message,
      style: style,
      showsSpinner: showsSpinner,
      actionTitle: actionTitle,
      action: action
    )
    toastModel = model

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
    } else {
      host = NSHostingView(rootView: banner)
      host.translatesAutoresizingMaskIntoConstraints = false
      host.alphaValue = 0
      toastHostingView = host
      containerView.addSubview(host)

      let topConstraint = host.topAnchor.constraint(equalTo: containerView.topAnchor, constant: toastHiddenTopOffset)
      toastTopConstraint = topConstraint
      NSLayoutConstraint.activate([
        topConstraint,
        host.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
        host.widthAnchor.constraint(lessThanOrEqualTo: containerView.widthAnchor, constant: -36),
      ])
      containerView.layoutSubtreeIfNeeded()
    }

    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.2
      host.animator().alphaValue = 1
      toastTopConstraint?.animator().constant = toastVisibleTopOffset
      containerView.animator().layoutSubtreeIfNeeded()
    }

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
  private var toastContent: some View {
    let shape = Capsule()
    let content = HStack(spacing: 10) {
      if model.showsSpinner {
        ProgressView()
          .controlSize(.small)
      }

      Image(systemName: iconName)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(iconColor)

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

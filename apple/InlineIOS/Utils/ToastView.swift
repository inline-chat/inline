import SwiftUI

struct ToastView: View {
  let toast: ToastData
  @State private var animationProgress: Double = 0
  @State private var previousMessage: String = ""
  private let toastManager = ToastManager.shared
  private let bubbleCornerRadius: CGFloat = 24
  private let clusterSpacing: CGFloat = 12

  var body: some View {
    toastCluster
      .animation(.spring(response: 0.4, dampingFraction: 0.8), value: toast.id)
      .transition(.move(edge: .bottom).combined(with: .opacity))
      .scaleEffect(toast.message != previousMessage ? 1.02 : 1.0)
      .animation(.spring(response: 0.3, dampingFraction: 0.76), value: toast.message)
      .onAppear {
        animationProgress = 1.0
        previousMessage = toast.message
      }
      .onChange(of: toast.message) { _, newMessage in
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
          previousMessage = newMessage
        }
      }
  }

  private func getStepNumber(for message: String) -> Int {
    switch message {
      case let msg where msg.contains("Processing"):
        1
      case let msg where msg.contains("Assigning users"):
        2
      case let msg where msg.contains("Generating issue"):
        3
      case let msg where msg.contains("Creating Notion page"):
        4
      default:
        1
    }
  }

  @ViewBuilder
  private var toastCluster: some View {
    if #available(iOS 26.0, *), toast.actionTitle != nil {
      GlassEffectContainer(spacing: clusterSpacing) {
        toastClusterContent
      }
    } else {
      toastClusterContent
    }
  }

  @ViewBuilder
  private var toastClusterContent: some View {
    if toast.actionTitle != nil {
      ViewThatFits {
        HStack(alignment: .bottom, spacing: clusterSpacing) {
          toastBubble
          toastActionButton
        }

        VStack(alignment: .trailing, spacing: 10) {
          toastBubble
          toastActionButton
        }
      }
    } else {
      toastBubble
    }
  }

  private var toastBubble: some View {
    HStack(alignment: toast.showsProgressDetails ? .top : .center, spacing: 10) {
      toastIcon

      VStack(alignment: .leading, spacing: toast.showsProgressDetails ? 4 : 0) {
        Text(toast.message)
          .font(.callout.weight(.semibold))
          .foregroundStyle(.primary)
          .multilineTextAlignment(.leading)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
          .transition(.move(edge: .trailing).combined(with: .opacity))
          .id(toast.message)

        if toast.showsProgressDetails {
          HStack(spacing: 6) {
            progressDots

            Text("Step \(getStepNumber(for: toast.message)) of 4")
              .font(.footnote.weight(.medium))
              .monospacedDigit()
              .foregroundStyle(.secondary)
              .transition(.opacity.combined(with: .scale(scale: 0.9)))
              .id("step-\(getStepNumber(for: toast.message))")
          }
        }
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, toast.showsProgressDetails ? 12 : 10)
    .modifier(ToastBubbleSurfaceModifier(toast: toast, cornerRadius: bubbleCornerRadius))
    .contentShape(.rect(cornerRadius: bubbleCornerRadius))
    .onTapGesture {
      toastManager.hideToast()
    }
  }

  @ViewBuilder
  private var toastIcon: some View {
    if let systemImage = toast.systemImage {
      if systemImage == "notion-logo" || systemImage == "linear-icon" {
        Image(systemImage)
          .resizable()
          .scaledToFit()
          .frame(width: 16, height: 16)
          .padding(.top, toast.showsProgressDetails ? 3 : 0)
          .transition(.scale.combined(with: .opacity))
          .id(systemImage)
      } else {
        Image(systemName: systemImage)
          .font(.callout.weight(.semibold))
          .foregroundStyle(iconForegroundColor)
          .padding(.top, toast.showsProgressDetails ? 3 : 0)
          .transition(.scale.combined(with: .opacity))
          .id(systemImage)
      }
    }
  }

  private var progressDots: some View {
    HStack(spacing: 4) {
      ForEach(0 ..< 3, id: \.self) { index in
        Circle()
          .fill(Color.secondary)
          .frame(width: 4, height: 4)
          .scaleEffect(animationProgress > Double(index) * 0.33 ? 1.1 : 0.82)
          .opacity(animationProgress > Double(index) * 0.33 ? 1.0 : 0.42)
          .animation(
            .easeInOut(duration: 0.6)
              .repeatForever(autoreverses: true)
              .delay(Double(index) * 0.2),
            value: animationProgress
          )
      }
    }
  }

  @ViewBuilder
  private var toastActionButton: some View {
    if let actionTitle = toast.actionTitle {
      if #available(iOS 26.0, *) {
        Button(actionTitle) {
          toast.action?()
        }
        .font(.callout.weight(.semibold))
        .buttonStyle(.glassProminent)
        .controlSize(.regular)
        .tint(actionTintColor)
        .transition(.opacity)
        .id(actionTitle)
      } else {
        Button(actionTitle) {
          toast.action?()
        }
        .font(.callout.weight(.semibold))
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .buttonBorderShape(.capsule)
        .tint(actionTintColor)
        .transition(.opacity)
        .id(actionTitle)
      }
    }
  }

  private var iconForegroundColor: Color {
    toast.statusAccentColor
  }

  private var actionTintColor: Color {
    .accentColor
  }
}

struct ToastContainerModifier: ViewModifier {
  @ObservedObject private var toastManager = ToastManager.shared

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .bottom) {
        if let toast = toastManager.currentToast {
          ToastView(toast: toast)
            .padding(.horizontal, 16)
            .safeAreaPadding(.bottom, 10)
        }
      }
  }
}

extension View {
  func toastView() -> some View {
    modifier(ToastContainerModifier())
  }
}

private struct ToastBubbleSurfaceModifier: ViewModifier {
  let toast: ToastData
  let cornerRadius: CGFloat

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
    } else {
      content
        .background {
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.thinMaterial)
            .overlay {
              RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(toast.fallbackFillColor)
            }
            .overlay {
              RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(toast.fallbackStrokeColor, lineWidth: 1)
            }
        }
    }
  }
}

private extension ToastData {
  var showsProgressDetails: Bool {
    type == .info && shouldStayVisible
  }

  var statusAccentColor: Color {
    switch type {
      case .success:
        Color(uiColor: .systemGreen)
      case .error:
        Color(uiColor: .systemRed)
      case .loading:
        .accentColor
      case .info:
        Color(uiColor: .secondaryLabel)
    }
  }

  var fallbackFillColor: Color {
    switch type {
      case .success:
        Color(uiColor: .systemGreen).opacity(0.14)
      case .error:
        Color(uiColor: .systemRed).opacity(0.14)
      case .loading:
        Color.accentColor.opacity(0.12)
      case .info:
        Color(uiColor: .secondarySystemBackground).opacity(0.7)
    }
  }

  var fallbackStrokeColor: Color {
    switch type {
      case .success:
        Color(uiColor: .systemGreen).opacity(0.22)
      case .error:
        Color(uiColor: .systemRed).opacity(0.2)
      case .loading:
        Color.accentColor.opacity(0.18)
      case .info:
        Color.primary.opacity(0.08)
    }
  }
}

#Preview {
  VStack(spacing: 20) {
    // Progress toast - Step 1
    ToastView(
      toast: ToastData(
        message: "Processing",
        type: .info,
        systemImage: "cylinder.split.1x2",
        shouldStayVisible: true
      )
    )

    // Progress toast - Step 3 (to show numeric transition)
    ToastView(
      toast: ToastData(
        message: "Generating issue",
        type: .info,
        systemImage: "brain.head.profile",
        shouldStayVisible: true
      )
    )

    // Success toast with action
    ToastView(
      toast: ToastData(
        message: "Created: Fix login bug",
        type: .success,
        action: {},
        actionTitle: "Open",
        systemImage: "checkmark.circle.fill"
      )
    )

    // Error toast
    ToastView(
      toast: ToastData(
        message: "Failed to create task",
        type: .error,
        systemImage: "xmark.circle.fill"
      )
    )
  }
  .padding()
  .background(Color(.systemBackground))
}

import SwiftUI

struct ToastView: View {
  let toast: ToastData
  @State private var animationProgress: Double = 0
  @State private var previousMessage: String = ""
  let theme = ThemeManager.shared.selected
  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      if let systemImage = toast.systemImage {
        if systemImage == "notion-logo" {
          Image("notion-logo")
            .resizable()
            .frame(width: 18, height: 18)
            .padding(.top, 2)
            .transition(.asymmetric(
              insertion: .scale.combined(with: .opacity),
              removal: .scale.combined(with: .opacity)
            ))
            .id(systemImage)
        } else {
          Image(systemName: systemImage)
            .foregroundColor(
              toast
                .type == .success ? Color(theme.toastSuccess ?? .green) : .primary.opacity(0.6)
            )
            .padding(.top, 2)
            .transition(.asymmetric(
              insertion: .scale.combined(with: .opacity),
              removal: .scale.combined(with: .opacity)
            ))
            .id(systemImage)
        }
      }

      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(toast.message)
            .foregroundColor(.primary)
            .transition(.asymmetric(
              insertion: .move(edge: .trailing).combined(with: .opacity),
              removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .id(toast.message)

          if toast.type == .info, toast.shouldStayVisible {
            Spacer()

            // Animated progress indicator
            HStack(spacing: 2) {
              ForEach(0 ..< 3, id: \.self) { index in
                Circle()
                  .fill(.secondary)
                  .frame(width: 4, height: 4)
                  .scaleEffect(animationProgress > Double(index) * 0.33 ? 1.2 : 0.8)
                  .opacity(animationProgress > Double(index) * 0.33 ? 1.0 : 0.4)
                  .animation(
                    .easeInOut(duration: 0.6)
                      .repeatForever(autoreverses: true)
                      .delay(Double(index) * 0.2),
                    value: animationProgress
                  )
              }
            }
          }
        }

        if toast.type == .info, toast.shouldStayVisible {
          HStack(spacing: 4) {
            Text("Step")
              .font(.caption2)
              .foregroundColor(.secondary)

            Text("\(getStepNumber(for: toast.message))")
              .font(.caption2.monospacedDigit())
              .foregroundColor(.primary)
              .transition(.opacity.combined(with: .scale(scale: 0.8)))
              .animation(.spring(response: 0.4, dampingFraction: 0.8), value: getStepNumber(for: toast.message))
              .id("step-\(getStepNumber(for: toast.message))")

            Text("of 4")
              .font(.caption2)
              .foregroundColor(.secondary)

            Spacer()
          }
        }
      }

      Spacer()

      if let actionTitle = toast.actionTitle {
        Button(actionTitle) {
          toast.action?()
        }
        .foregroundColor(
          toast.type == .success ? Color(theme.toastSuccess ?? .green) : toast.type == .error
            ? Color(theme.toastFailed ?? .red) : Color(theme.toastInfo ?? .blue)
        )
        .padding(.leading, 4)
        .transition(.opacity)
        .id(actionTitle)
      }
    }
    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: toast.id)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(
      ZStack {
        RoundedRectangle(cornerRadius: 20)
          .fill(.thinMaterial)
        RoundedRectangle(cornerRadius: 20)
          .fill(
            toast.type == .success ?
              Color(theme.toastSuccess ?? .green).opacity(0.1) : toast
              .type == .error ? Color(theme.toastFailed ?? .red)
              .opacity(0.1) : Color(theme.toastInfo ?? .systemGray6).opacity(0.1)
          )
          .strokeBorder(
            toast.type == .success ?
              Color(theme.toastSuccess ?? .green).opacity(0.2) : toast.type == .error
              ? Color(theme.toastFailed ?? .red).opacity(0.1) : Color(theme.toastInfo ?? .label).opacity(0.08),

            lineWidth: 1
          )
      }
    )
    .padding(.horizontal, 20)
    .shadow(color: Color.primary.opacity(0.06), radius: 8, x: 0, y: 3)
    .transition(
      .asymmetric(
        insertion: .opacity.combined(with: .move(edge: .top)),
        removal: .opacity.combined(with: .move(edge: .top))
      )
    )
    .scaleEffect(toast.message != previousMessage ? 1.05 : 1.0)
    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: toast.message)
    .onAppear {
      animationProgress = 1.0
      previousMessage = toast.message
    }
    .onChange(of: toast.message) { newMessage in
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
}

struct ToastContainerModifier: ViewModifier {
  @StateObject private var toastManager = ToastManager.shared

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .bottom) {
        if let toast = toastManager.currentToast {
          VStack {
            Spacer()
            ToastView(toast: toast)
              .padding(.bottom, 60)
          }
        }
      }
  }
}

extension View {
  func toastView() -> some View {
    modifier(ToastContainerModifier())
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

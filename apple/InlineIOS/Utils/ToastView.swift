import SwiftUI

struct ToastView: View {
  let toast: ToastData

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      if let systemImage = toast.systemImage {
        Image(systemName: systemImage)
          .foregroundColor(toast.type == .success ? .green : .secondary)
          .padding(.top, 2)
          .transition(.asymmetric(
            insertion: .scale.combined(with: .opacity),
            removal: .scale.combined(with: .opacity)
          ))
          .id(systemImage)
      }

      Text(toast.message)
        .foregroundColor(.primary)
        .transition(.opacity)
        .id(toast.message)

      Spacer()

      if let actionTitle = toast.actionTitle {
        Button(actionTitle) {
          toast.action?()
        }
        .foregroundColor(toast.type == .success ? .green : .blue)
        .padding(.leading, 4)
        .transition(.opacity)
        .id(actionTitle)
      }
    }
    .animation(.spring(response: 0.3), value: toast.id)
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
              Color.green.opacity(0.1) : Color(uiColor: .systemGray6)
          )
          .strokeBorder(
            toast.type == .success ?
              Color.green.opacity(0.2) : Color.primary.opacity(0.08),

            lineWidth: 1
          )
      }
    )
    .padding(.horizontal, 20)
    .transition(.move(edge: .top).combined(with: .opacity))
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
    // Loading toast
    ToastView(
      toast: ToastData(
        message: "Creating Linear issue...",
        type: .loading,
        systemImage: "circle.dotted"
      )
    )

    // Success toast with action
    ToastView(
      toast: ToastData(
        message: "Issue created successfully",
        type: .success,
        action: {},
        actionTitle: "Open",
        systemImage: "checkmark.circle.fill"
      )
    )

    // Info toast
    ToastView(
      toast: ToastData(
        message: "Something went wrong",
        type: .info,
        systemImage: "xmark.circle.fill"
      )
    )
  }
  .padding()
  .background(Color(.systemBackground))
}

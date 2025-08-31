import InlineKit
import SwiftUI

struct VisibilityView: View {
  var theme = ThemeManager.shared.selected

  @Binding private var selectedChatType: ChatType
  @Binding private var selectedRoute: Route
  @Binding private var selectedSpaceName: String?
  let formState: FormStateObject

  let createChat: () -> Void

  init(
    selectedChatType: Binding<ChatType>,
    selectedRoute: Binding<Route>,
    selectedSpaceName: Binding<String?>,
    formState: FormStateObject,
    createChat: @escaping () -> Void
  ) {
    _selectedChatType = selectedChatType
    _selectedRoute = selectedRoute
    _selectedSpaceName = selectedSpaceName
    self.formState = formState
    self.createChat = createChat
  }

  @ViewBuilder
  var trailingButton: some View {
    if selectedChatType == .private {
      if #available(iOS 26.0, *) {
        Button(action: {
          selectedRoute = .selectParticipants
        }) {
          Image(systemName: "arrow.right")
        }
        .buttonStyle(.glassProminent)
      } else {
        Button(action: {
          selectedRoute = .selectParticipants
        }) {
          Text("Next")
        }
        .tint(Color(theme.accent))
      }
    } else {
      if #available(iOS 26.0, *) {
        Button(action: {
          createChat()
        }) {
          if formState.isLoading {
            ProgressView()
              .scaleEffect(0.8)
          } else {
            Image(systemName: "arrow.right")
          }
        }
        .buttonStyle(.glassProminent)
        .disabled(formState.isLoading)
      } else {
        Button(action: {
          createChat()
        }) {
          Text(formState.isLoading ? "Creating..." : "Create")
        }
        .tint(Color(theme.accent))
        .disabled(formState.isLoading)
      }
    }
  }

  var body: some View {
    VStack {
      VStack(spacing: 12) {
        Button(action: {
          selectedChatType = .public
        }) {
          HStack(spacing: 12) {
            Image(systemName: selectedChatType == .public ? "largecircle.fill.circle" : "circle")
              .foregroundColor(selectedChatType == .public ? Color(theme.accent) : .secondary)
              .animation(.easeInOut(duration: 0.08), value: selectedChatType)

            VStack(alignment: .leading, spacing: 0) {
              Text("Public")
                .foregroundColor(.primary)
              // TODO: replace it with space name
              Text("Everyone in \(selectedSpaceName ?? "Space")")
                .foregroundStyle(.secondary)
                .font(.subheadline)
            }

            Spacer()
          }
          .frame(maxWidth: .infinity)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        Divider()
        Button(action: {
          selectedChatType = .private
        }) {
          HStack(spacing: 12) {
            Image(systemName: selectedChatType == .private ? "largecircle.fill.circle" : "circle")
              .foregroundColor(selectedChatType == .private ? Color(theme.accent) : .secondary)
              .animation(.easeInOut(duration: 0.08), value: selectedChatType)

            VStack(alignment: .leading, spacing: 0) {
              Text("Private")
                .foregroundColor(.primary)
              Text("Only selected members")
                .foregroundStyle(.secondary)
                .font(.subheadline)
            }

            Spacer()
          }
          .frame(maxWidth: .infinity)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .navigationBarBackButtonHidden()
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button(action: {
          selectedRoute = .createNewChat
        }) {
          Image(systemName: "chevron.left")
        }
        .tint(Color(theme.accent))
      }
      ToolbarItem(placement: .topBarTrailing) {
        trailingButton
      }
    }
  }
}

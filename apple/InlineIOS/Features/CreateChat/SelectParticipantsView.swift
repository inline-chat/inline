import GRDB
import InlineKit
import InlineUI
import Logger
import SwiftUI

struct SelectParticipantsView: View {
  @State private var searchText = ""

  @Binding var selectedParticipants: Set<Int64>
  @Binding var selectedRoute: Route
  let formState: FormStateObject

  let createChat: () -> Void

  @EnvironmentStateObject private var participantSearchViewModel: ParticipantSearchViewModel
  @EnvironmentStateObject private var spaceViewModel: FullSpaceViewModel

  init(
    selectedParticipants: Binding<Set<Int64>>,
    spaceId: Int64,
    selectedRoute: Binding<Route>,
    formState: FormStateObject,
    createChat: @escaping () -> Void
  ) {
    _participantSearchViewModel = EnvironmentStateObject { env in
      ParticipantSearchViewModel(db: env.appDatabase, spaceId: spaceId)
    }
    _spaceViewModel = EnvironmentStateObject { env in
      FullSpaceViewModel(db: env.appDatabase, spaceId: spaceId)
    }
    _selectedParticipants = selectedParticipants
    _selectedRoute = selectedRoute
    self.formState = formState
    self.createChat = createChat
  }

  @ViewBuilder
  var trailingButton: some View {
    if #available(iOS 26.0, *) {
      Button(action: {
        createChat()
      }) {
        if formState.isLoading {
          ProgressView()
            .scaleEffect(0.8)
        } else {
          Image(systemName: "checkmark")
        }
      }
      .buttonStyle(.glassProminent)
      .disabled(selectedParticipants.count == 0 || formState.isLoading)
    } else {
      Button(action: {
        createChat()
      }) {
        Text(formState.isLoading ? "Creating..." : "Create")
      }
      .tint(Color(uiColor: UIColor(hex: "#52A5FF")!))
      .disabled(selectedParticipants.count == 0 || formState.isLoading)
    }
  }

  var body: some View {
    Group {
      Section {
        TextField("Search in users by username, first name, last name", text: $searchText)
          .textFieldStyle(.plain)
          .font(.body)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background {
            RoundedRectangle(cornerRadius: 18)
              .fill(Color(.tertiarySystemFill))
          }
          .onChange(of: searchText) {
            participantSearchViewModel.search(query: searchText)
          }
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
          .navigationBarBackButtonHidden()
          .toolbar {
            ToolbarItem(placement: .topBarLeading) {
              Button(action: {
                selectedRoute = .visibility
              }) {
                Image(systemName: "chevron.left")
              }
              .tint(Color(uiColor: UIColor(hex: "#52A5FF")!))
            }
            ToolbarItem(placement: .topBarTrailing) {
              trailingButton
            }
          }
      }
      if searchText.isEmpty {
        ForEach(spaceViewModel.members, id: \.userInfo.user.id) { member in

          UserRow(
            userInfo: member.userInfo,
            selectedParticipants: $selectedParticipants
          )
        }
      } else {
        ForEach(participantSearchViewModel.results, id: \.user.id) { userInfo in
          Button(action: {
            if selectedParticipants.contains(userInfo.user.id) {
              selectedParticipants.remove(userInfo.user.id)
            } else {
              selectedParticipants.insert(userInfo.user.id)
            }
          }) {
            UserRow(
              userInfo: userInfo,
              selectedParticipants: $selectedParticipants
            )
          }
        }
      }
    }
  }
}

struct UserRow: View {
  let userInfo: UserInfo
  @Binding var selectedParticipants: Set<Int64>

  var body: some View {
    HStack(spacing: 10) {
      Circle()
        .fill(selectedParticipants.contains(userInfo.user.id) ? Color(uiColor: UIColor(hex: "#52A5FF")!) : Color.clear)
        .stroke(selectedParticipants.contains(userInfo.user.id) ? Color(uiColor: UIColor(hex: "#52A5FF")!) : Color.gray, lineWidth: 1)
        .frame(width: 18, height: 18)
        .scaleEffect(selectedParticipants.contains(userInfo.user.id) ? 1.0 : 0.8)
        .animation(
          .spring(response: 0.3, dampingFraction: 0.6, blendDuration: 0),
          value: selectedParticipants.contains(userInfo.user.id)
        )
        .overlay {
          if selectedParticipants.contains(userInfo.user.id) {
            Image(systemName: "checkmark")
              .foregroundColor(.white)
              .font(.system(size: 12))
              .opacity(selectedParticipants.contains(userInfo.user.id) ? 1.0 : 0.0)
              .scaleEffect(selectedParticipants.contains(userInfo.user.id) ? 1.0 : 0.8)
              .animation(
                .spring(response: 0.3, dampingFraction: 0.6, blendDuration: 0)
                  .delay(selectedParticipants.contains(userInfo.user.id) ? 0.1 : 0),
                value: selectedParticipants.contains(userInfo.user.id)
              )
          }
        }
      UserAvatar(userInfo: userInfo, size: 48)
      VStack(alignment: .leading, spacing: -2) {
        Text(userInfo.user.firstName ?? "")
          .font(.body)
          .foregroundColor(.primary)
        Text("@\(userInfo.user.username ?? "")")
          .font(.subheadline)
          .foregroundColor(.secondary)
      }
      Spacer()
    }
    .contentShape(Rectangle())
    .onTapGesture {
      if selectedParticipants.contains(userInfo.user.id) {
        selectedParticipants.remove(userInfo.user.id)
      } else {
        selectedParticipants.insert(userInfo.user.id)
      }
    }
  }
}

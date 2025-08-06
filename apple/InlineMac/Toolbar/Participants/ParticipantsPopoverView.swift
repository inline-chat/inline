import InlineKit
import InlineUI
import SwiftUI

public struct ParticipantsPopoverView: View {
  let participants: [UserInfo]
  let currentUserId: Int64?
  @Binding var isPresented: Bool
  @State private var searchText = ""
  
  public init(participants: [UserInfo], currentUserId: Int64?, isPresented: Binding<Bool>) {
    self.participants = participants
    self.currentUserId = currentUserId
    self._isPresented = isPresented
  }
  
  private var filteredParticipants: [UserInfo] {
    if searchText.isEmpty {
      return participants
    }
    return participants.filter { participant in
      let name = "\(participant.user.firstName ?? "") \(participant.user.lastName ?? "")".trimmingCharacters(in: .whitespaces)
      let username = participant.user.username ?? ""
      let email = participant.user.email ?? ""
      
      return name.localizedCaseInsensitiveContains(searchText) ||
             username.localizedCaseInsensitiveContains(searchText) ||
             email.localizedCaseInsensitiveContains(searchText)
    }
  }
  
  private var shouldShowSearch: Bool {
    participants.count >= 10
  }
  
  public var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      // Header
      Text("Participants (\(participants.count))")
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.top, 6)
      
      // Search (for 10+ participants)
      if shouldShowSearch {
        SearchField(text: $searchText, placeholder: "Search participants...")
          .padding(.horizontal, 10)
      }
      
      // Participant List
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(filteredParticipants, id: \.id) { participant in
            ParticipantRow(
              participant: participant,
              isCurrentUser: participant.id == currentUserId
            )
            .padding(.horizontal, 10)
          }
        }
        .padding(.vertical, 2)
      }
      .frame(maxHeight: shouldShowSearch ? 200 : 220)
    }
    .padding(.bottom, 4)
  }
}

private struct ParticipantRow: View {
  let participant: UserInfo
  let isCurrentUser: Bool
  
  var body: some View {
    HStack(spacing: 8) {
      UserAvatar(user: participant.user, size: 24)
      
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 4) {
          Text(displayName)
            .font(.system(size: 12, weight: .medium))
          
          if isCurrentUser {
            Text("(You)")
              .font(.system(size: 10))
              .foregroundColor(.secondary)
          }
        }
      }
      
      Spacer()
    }
    .padding(.vertical, 3)
    .contentShape(Rectangle())
  }
  
  private var displayName: String {
    let name = "\(participant.user.firstName ?? "") \(participant.user.lastName ?? "")".trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? (participant.user.username ?? participant.user.email ?? "Unknown") : name
  }
}

private struct SearchField: View {
  @Binding var text: String
  let placeholder: String
  
  var body: some View {
    HStack {
      Image(systemName: "magnifyingglass")
        .foregroundColor(.secondary)
        .font(.system(size: 12))
      
      TextField(placeholder, text: $text)
        .textFieldStyle(.plain)
        .font(.system(size: 12))
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(Color.gray.opacity(0.1))
    .cornerRadius(4)
  }
}
import InlineKit
import SwiftUI

public struct UserGroupMembersSheet: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var viewModel: UserGroupDetailsViewModel

  public init(target: UserGroupMentionTarget) {
    self.init(groupId: target.groupId, spaceId: target.spaceId)
  }

  public init(groupId: Int64, spaceId: Int64?) {
    _viewModel = StateObject(wrappedValue: UserGroupDetailsViewModel(groupId: groupId, spaceId: spaceId))
  }

  public var body: some View {
    sheetBody
      .task {
        await viewModel.refresh()
      }
  }

  @ViewBuilder
  private var sheetBody: some View {
    #if os(iOS)
    navigationContent
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
    #else
    navigationContent
      .frame(width: 360)
      .frame(minHeight: 260)
    #endif
  }

  private var navigationContent: some View {
    NavigationStack {
      Group {
        if !viewModel.hasLoadedLocalSnapshot {
          Color.clear
        } else if let group = viewModel.group {
          UserGroupMembersList(group: group, members: viewModel.members)
        } else {
          UserGroupUnavailableView(errorMessage: viewModel.errorMessage)
        }
      }
      .overlay {
        if viewModel.isLoading, viewModel.group == nil {
          ProgressView()
        }
      }
      .navigationTitle(viewModel.group?.name ?? "User Group")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") {
            dismiss()
          }
        }
      }
    }
  }
}

private struct UserGroupMembersList: View {
  let group: UserGroup
  let members: [UserGroupMemberInfo]

  var body: some View {
    List {
      Section {
        UserGroupSummaryRow(
          name: group.name,
          description: group.description,
          memberCount: group.memberCount
        )
      }

      Section {
        if members.isEmpty {
          Text("No members")
            .foregroundStyle(.secondary)
        } else {
          ForEach(members) { member in
            UserGroupMemberRow(userInfo: member.userInfo)
          }
        }
      }
    }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #else
    .listStyle(.inset)
    #endif
  }
}

private struct UserGroupSummaryRow: View {
  let name: String
  let description: String?
  let memberCount: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(name)
        .font(.headline)
        .lineLimit(2)

      if let description, !description.isEmpty {
        Text(description)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }

      Text(memberCountText)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 2)
  }

  private var memberCountText: String {
    memberCount == 1 ? "1 member" : "\(memberCount) members"
  }
}

private struct UserGroupMemberRow: View {
  let userInfo: UserInfo

  var body: some View {
    HStack(spacing: 10) {
      UserAvatar(userInfo: userInfo, size: 30)

      Text(userInfo.user.displayName)
        .font(.body)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 2)
  }
}

private struct UserGroupUnavailableView: View {
  let errorMessage: String?

  var body: some View {
    ContentUnavailableView(
      "User Group Unavailable",
      systemImage: "person.3",
      description: Text(errorMessage ?? "This group is not available locally.")
    )
  }
}

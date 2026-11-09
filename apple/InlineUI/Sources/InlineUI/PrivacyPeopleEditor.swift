import InlineKit
import SwiftUI

/// Edits one privacy exception list: who is in it, and people to add.
public struct PrivacyPeopleEditor: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var model = PrivacyPeoplePickerModel()

  private let title: String
  private let footer: String
  private let initialIDs: [Int64]
  private let onSave: ([Int64]) -> Void

  public init(title: String, footer: String, selectedIDs: [Int64], onSave: @escaping ([Int64]) -> Void) {
    self.title = title
    self.footer = footer
    initialIDs = selectedIDs
    self.onSave = onSave
  }

  public var body: some View {
    NavigationStack {
      List {
        Section {
          if model.selectedUsers.isEmpty, model.unresolvedIDs.isEmpty {
            Text("No one added")
              .foregroundStyle(.secondary)
          }
          ForEach(model.selectedUsers) { userInfo in
            PrivacyPersonRow(userInfo: userInfo) {
              Button {
                model.remove(id: userInfo.id)
              } label: {
                Image(systemName: "minus.circle.fill")
                  .foregroundStyle(.red)
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Remove \(userInfo.user.displayName)")
            }
          }
          if !model.unresolvedIDs.isEmpty {
            Text(model.unresolvedIDs.count == 1 ? "1 more person" : "\(model.unresolvedIDs.count) more people")
              .foregroundStyle(.secondary)
          }
        } footer: {
          Text(footer)
        }

        Section(model.searchText.isEmpty ? "People You Chat With" : "Results") {
          ForEach(model.candidates) { userInfo in
            Button {
              model.add(userInfo)
            } label: {
              PrivacyPersonRow(userInfo: userInfo) {
                Image(systemName: "plus.circle.fill")
                  .foregroundStyle(.tint)
              }
            }
            .buttonStyle(.plain)
          }
          if model.candidates.isEmpty, !model.isSearching {
            Text(model.searchText.isEmpty ? "Search to find people" : "No people found")
              .foregroundStyle(.secondary)
          }
        }
      }
      .searchable(text: $model.searchText, prompt: "Search people")
      .navigationTitle(title)
      #if os(iOS)
      .listStyle(.insetGrouped)
      .navigationBarTitleDisplayMode(.inline)
      #else
      .listStyle(.inset)
      .frame(width: 400, height: 480)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            onSave(model.selectedIDs)
            dismiss()
          }
        }
      }
    }
    .task { await model.load(selectedIDs: initialIDs) }
  }
}

private struct PrivacyPersonRow<Accessory: View>: View {
  let userInfo: UserInfo
  @ViewBuilder let accessory: () -> Accessory

  var body: some View {
    HStack(spacing: 10) {
      UserAvatar(userInfo: userInfo, size: 28)
      VStack(alignment: .leading, spacing: 1) {
        Text(userInfo.user.displayName)
          .lineLimit(1)
        if let username = userInfo.user.username, !username.isEmpty {
          Text("@\(username)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      accessory()
    }
    .contentShape(Rectangle())
  }
}

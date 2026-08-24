#if DEBUG || DEBUG_BUILD
import AppKit
import InlineUI
import SwiftUI

struct DeveloperPlaygroundView: View {
  @State private var selectedScope: DeveloperPlaygroundScope? = .notifications
  @State private var appearance = DeveloperPlaygroundAppearance.system
  @State private var inviteLayout = DeveloperInviteLayout.focused
  @State private var messageConfiguration = DeveloperMessagePlaygroundConfiguration()
  @State private var sidebarModel = DeveloperSidebarPlaygroundModel()

  var body: some View {
    NavigationSplitView {
      List(selection: $selectedScope) {
        Section("Components") {
          Label(DeveloperPlaygroundScope.avatars.title, systemImage: DeveloperPlaygroundScope.avatars.iconName)
            .tag(DeveloperPlaygroundScope.avatars)
          Label(
            DeveloperPlaygroundScope.notifications.title,
            systemImage: DeveloperPlaygroundScope.notifications.iconName
          )
          .tag(DeveloperPlaygroundScope.notifications)
          Label(
            DeveloperPlaygroundScope.messageViews.title,
            systemImage: DeveloperPlaygroundScope.messageViews.iconName
          )
          .tag(DeveloperPlaygroundScope.messageViews)
          Label(
            DeveloperPlaygroundScope.sidebarRows.title,
            systemImage: DeveloperPlaygroundScope.sidebarRows.iconName
          )
          .tag(DeveloperPlaygroundScope.sidebarRows)
        }

        Section("Experiments") {
          Label(
            DeveloperPlaygroundScope.invitePageExperiment.title,
            systemImage: DeveloperPlaygroundScope.invitePageExperiment.iconName
          )
          .tag(DeveloperPlaygroundScope.invitePageExperiment)
        }
      }
      .navigationTitle("Playground")
      .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
    } detail: {
      switch selectedScope {
      case .invitePageExperiment:
        DeveloperPlaygroundInviteView(selectedLayout: $inviteLayout)
      case .avatars:
        DeveloperPlaygroundAvatarView()
      case .notifications:
        DeveloperPlaygroundNotificationView()
      case .messageViews:
        DeveloperPlaygroundMessageView(configuration: $messageConfiguration)
      case .sidebarRows:
        DeveloperPlaygroundSidebarView(model: sidebarModel)
      case nil:
        ContentUnavailableView(
          "Select a playground",
          systemImage: "square.grid.2x2",
          description: Text("Choose a page from the sidebar.")
        )
      }
    }
    .navigationSplitViewStyle(.balanced)
    .inspector(isPresented: .constant(true)) {
      DeveloperPlaygroundInspector(
        appearance: $appearance,
        selectedScope: selectedScope,
        inviteLayout: $inviteLayout,
        messageConfiguration: $messageConfiguration,
        sidebarModel: sidebarModel
      )
        .inspectorColumnWidth(min: 200, ideal: 220, max: 280)
    }
    .preferredColorScheme(appearance.colorScheme)
  }
}

private enum DeveloperPlaygroundScope: String, CaseIterable, Identifiable {
  case avatars
  case notifications
  case messageViews
  case sidebarRows
  case invitePageExperiment

  var id: Self { self }

  var title: String {
    switch self {
    case .avatars:
      "Avatars"
    case .notifications:
      "Notifications"
    case .messageViews:
      "Message Views"
    case .sidebarRows:
      "Sidebar Rows"
    case .invitePageExperiment:
      "August 13th · Invite page"
    }
  }

  var iconName: String {
    switch self {
    case .avatars:
      "person.crop.circle"
    case .notifications:
      "bell.badge"
    case .messageViews:
      "bubble.left.and.bubble.right"
    case .sidebarRows:
      "sidebar.left"
    case .invitePageExperiment:
      "flask"
    }
  }
}

private enum DeveloperPlaygroundAppearance: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  var id: Self { self }

  var title: String {
    switch self {
    case .system:
      "System"
    case .light:
      "Light"
    case .dark:
      "Dark"
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system:
      nil
    case .light:
      .light
    case .dark:
      .dark
    }
  }
}

private struct DeveloperPlaygroundInspector: View {
  @Binding var appearance: DeveloperPlaygroundAppearance
  let selectedScope: DeveloperPlaygroundScope?
  @Binding var inviteLayout: DeveloperInviteLayout
  @Binding var messageConfiguration: DeveloperMessagePlaygroundConfiguration
  let sidebarModel: DeveloperSidebarPlaygroundModel

  var body: some View {
    Form {
      Section("Appearance") {
        Picker("Mode", selection: $appearance) {
          ForEach(DeveloperPlaygroundAppearance.allCases) { appearance in
            Text(appearance.title)
              .tag(appearance)
          }
        }
        .pickerStyle(.segmented)
      }

      if selectedScope == .invitePageExperiment {
        Section("Invite experiment") {
          Picker("Concept", selection: $inviteLayout) {
            ForEach(DeveloperInviteLayout.allCases) { layout in
              Text(verbatim: layout.title)
                .tag(layout)
            }
          }

          Text(verbatim: inviteLayout.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if selectedScope == .messageViews {
        DeveloperMessagePlaygroundInspector(configuration: $messageConfiguration)
      }

      if selectedScope == .sidebarRows {
        DeveloperSidebarPlaygroundInspector(model: sidebarModel)
      }
    }
    .formStyle(.grouped)
  }
}

private struct DeveloperPlaygroundAvatarView: View {
  private let identityFixtures = [
    DeveloperPlaygroundAvatarFixture(
      title: "Two initials",
      detail: "First and last name",
      userID: 1,
      firstName: "Ava",
      lastName: "Lin"
    ),
    DeveloperPlaygroundAvatarFixture(
      title: "One initial",
      detail: "First name only",
      userID: 2,
      firstName: "Mo"
    ),
    DeveloperPlaygroundAvatarFixture(
      title: "Email fallback",
      detail: "No display name",
      userID: 3,
      email: "design@inline.chat"
    ),
    DeveloperPlaygroundAvatarFixture(
      title: "Unicode",
      detail: "Non-Latin name",
      userID: 4,
      firstName: "علی",
      lastName: "رضایی"
    ),
    DeveloperPlaygroundAvatarFixture(
      title: "Empty identity",
      detail: "Person fallback",
      userID: 5
    ),
  ]

  private let sizes: [CGFloat] = [20, 24, 32, 40, 56, 72]
  private let opacities = [1.0, 0.7, 0.4]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Avatars")
            .font(.title2.weight(.semibold))
          Text("Deterministic fixtures rendered through InlineUI.UserAvatar.")
            .foregroundStyle(.secondary)
        }

        DeveloperPlaygroundSection(
          title: "Identity fallbacks",
          detail: "Common combinations of names and account identity."
        ) {
          LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(identityFixtures) { fixture in
              DeveloperPlaygroundAvatarFixtureCard(fixture: fixture, size: 44)
            }
          }
        }

        DeveloperPlaygroundSection(
          title: "Sizes",
          detail: "The same identity at common UI sizes."
        ) {
          HStack(alignment: .bottom, spacing: 22) {
            ForEach(sizes, id: \.self) { size in
              VStack(spacing: 8) {
                avatar(size: size)
                Text("\(Int(size))")
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
            }
          }
        }

        DeveloperPlaygroundSection(
          title: "Background opacity",
          detail: "Initials rendering with reduced background emphasis."
        ) {
          HStack(spacing: 22) {
            ForEach(opacities, id: \.self) { opacity in
              VStack(spacing: 8) {
                avatar(size: 44, backgroundOpacity: opacity)
                Text(opacity.formatted(.percent.precision(.fractionLength(0))))
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(24)
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var columns: [GridItem] {
    [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .topLeading)]
  }

  private func avatar(size: CGFloat, backgroundOpacity: Double = 1) -> some View {
    UserAvatar(
      userID: 10,
      firstName: "Ava",
      lastName: "Lin",
      email: nil,
      username: nil,
      stableAvatarIdentity: nil,
      remoteURL: nil,
      localURL: nil,
      size: size,
      backgroundOpacity: backgroundOpacity,
      cacheRemoteAvatar: false
    )
  }
}

private struct DeveloperPlaygroundSection<Content: View>: View {
  let title: String
  let detail: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
        Text(detail)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct DeveloperPlaygroundAvatarFixture: Identifiable {
  let title: String
  let detail: String
  let userID: Int64
  var firstName: String?
  var lastName: String?
  var email: String?
  var username: String?

  var id: Int64 { userID }
}

private struct DeveloperPlaygroundAvatarFixtureCard: View {
  let fixture: DeveloperPlaygroundAvatarFixture
  let size: CGFloat

  var body: some View {
    HStack(spacing: 12) {
      UserAvatar(
        userID: fixture.userID,
        firstName: fixture.firstName,
        lastName: fixture.lastName,
        email: fixture.email,
        username: fixture.username,
        stableAvatarIdentity: nil,
        remoteURL: nil,
        localURL: nil,
        size: size,
        cacheRemoteAvatar: false
      )

      VStack(alignment: .leading, spacing: 2) {
        Text(fixture.title)
          .font(.subheadline.weight(.medium))
        Text(fixture.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
    }
  }
}
#endif

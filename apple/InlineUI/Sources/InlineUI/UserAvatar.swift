import InlineKit
import Logger
import Nuke
import NukeUI
import SwiftUI

public struct UserAvatar: View, Equatable {
  public nonisolated static func == (lhs: UserAvatar, rhs: UserAvatar) -> Bool {
    lhs.firstName == rhs.firstName && lhs.lastName == rhs.lastName && lhs.email == rhs.email
      && lhs.username == rhs.username && lhs.size == rhs.size
      && lhs.ignoresSafeArea == rhs.ignoresSafeArea
      && lhs.remoteUrl == rhs.remoteUrl // ???
      && lhs.fileId == rhs.fileId && lhs.localUrl == rhs.localUrl
  }

  let firstName: String?
  let lastName: String?
  let email: String?
  let username: String?
  let size: CGFloat
  let ignoresSafeArea: Bool

  var file: File? = nil
  var fileId: String? = nil
  var remoteUrl: URL? = nil
  var localUrl: URL? = nil

  let nameForInitials: String

  public init(user: User, size: CGFloat = 32, ignoresSafeArea: Bool = false) {
    firstName = user.firstName
    lastName = user.lastName
    email = user.email
    username = user.username
    self.size = size
    self.ignoresSafeArea = ignoresSafeArea
    nameForInitials = Self.getNameForInitials(user: user)
  }

  public init(userInfo: UserInfo, size: CGFloat = 32, ignoresSafeArea: Bool = false) {
    let user = userInfo.user
    file = userInfo.profilePhoto?.first
    fileId = userInfo.profilePhoto?.first?.id
    remoteUrl = userInfo.profilePhoto?.first?.getRemoteURL()
    localUrl = userInfo.profilePhoto?.first?.getLocalURL()
    firstName = user.firstName
    lastName = user.lastName
    email = user.email
    username = user.username
    self.size = size
    self.ignoresSafeArea = ignoresSafeArea
    nameForInitials = Self.getNameForInitials(user: user)
  }

  public init(apiUser: ApiUser, size: CGFloat = 32, ignoresSafeArea: Bool = false) {
    firstName = apiUser.firstName
    lastName = apiUser.lastName
    email = apiUser.email
    username = apiUser.username
    self.size = size
    self.ignoresSafeArea = ignoresSafeArea
    nameForInitials = Self.getNameForInitials(user: apiUser)
  }

  // This must match below
  public static func getNameForInitials(user: User) -> String {
    let firstName = user.firstName ?? user.email?.components(separatedBy: "@").first ?? "User"
    let lastName = user.lastName
    let name = "\(firstName) \(lastName ?? "")"
    return name
  }

  static func getNameForInitials(user: ApiUser) -> String {
    let firstName = user.firstName ?? user.email?.components(separatedBy: "@").first ?? "User"
    let lastName = user.lastName
    let name = "\(firstName) \(lastName ?? "")"
    return name
  }

  @ViewBuilder
  public var placeholder: some View {
    Circle().fill(Color.gray.opacity(0.5)).frame(width: size, height: size).fixedSize()
  }

  @ViewBuilder
  public var initials: some View {
    InitialsCircle(
      name: nameForInitials,
      size: size
    )
    .equatable()
    .frame(width: size, height: size)
    .fixedSize()
  }

  @Environment(\.colorScheme) private var colorScheme

  @MainActor
  public enum ColorPalette {
    @MainActor

    static let colors: [Color] = [
      .pink.adjustLuminosity(by: -0.1),
      .orange,
      .purple,
      .yellow.adjustLuminosity(by: -0.1),
      .teal,
      .blue,
      .teal,
      .green,
      .primary,
      .red,
      .indigo,
      .mint,
      .cyan,
//      .gray,
//      .brown,
    ]

    public static func color(for name: String) -> Color {
      // let hash = name.hashValue
      let hash = name.utf8.reduce(0) { $0 + Int($1) }
      return colors[abs(hash) % colors.count]
    }
  }

  var name: String {
    "\(firstName ?? "") \(lastName ?? "")"
  }

  private var initialsName: String {
    name.first.map(String.init)?.uppercased() ?? ""
  }

  private var backgroundColor: Color {
    let baseColor = ColorPalette.color(for: name)
    return colorScheme == .dark
      ? baseColor.adjustLuminosity(by: -0.1)
      : baseColor.adjustLuminosity(by: 0)
  }

  private var backgroundGradient: LinearGradient {
    LinearGradient(
      colors: [
        backgroundColor.adjustLuminosity(by: 0.2),
        backgroundColor.adjustLuminosity(by: 0),
      ],
      startPoint: .top,
      endPoint: .bottom
    )
  }

  @ViewBuilder
  public var avatar: some View {
    if remoteUrl != nil || localUrl != nil {
      LazyImage(
        url: localUrl ?? remoteUrl,
        content: { state in

          if state.isLoading {
            placeholder
          } else if state.error != nil {
            initials
          } else {
            state.image?
              .resizable()
              .aspectRatio(contentMode: .fit)
              .frame(width: size, height: size)
              .background(backgroundGradient)
              .clipShape(Circle())
              .fixedSize()
              .task {
                // don't re-save if already
                guard localUrl == nil else { return }

                Log.shared.info("Loaded image, trying to save locally")
                // Save image locally when loaded
                if let nsImage = try? state.result?.get().image {
                  if var file {
                    let directory = FileHelpers.getDocumentsDirectory()
                    let fileName = file.fileName ?? ""
                    if let pathString = nsImage.save(
                      to: directory, withName: fileName, format: file.imageFormat
                    ) {
                      file.localPath = pathString
                      let file_ = file
                      try? await AppDatabase.shared.dbWriter.write { db in
                        try file_.save(db)
                      }
                    }
                  }
                }
              }
          }
        }
      )
    } else {
      initials
    }
  }

  public var body: some View {
    if ignoresSafeArea {
      avatar
        // Important so the toolbar safe area doesn't affect it
        .ignoresSafeArea()
    } else {
      avatar
    }
  }
}

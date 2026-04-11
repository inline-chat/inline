import Auth
import InlineConfig
import Logger
import Sentry

public final class Analytics: Sendable {
  // public static let shared = Analytics()

  private init() {}

  private static let log = Log.scoped("Analytics")

  #if DEBUG
  static let debugBuild = true
  #else
  static let debugBuild = false
  #endif

  static let runInDebugBuilds = false

  private static func bundleString(for key: String) -> String? {
    guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func sentryReleaseName() -> String? {
    guard let version = bundleString(for: "CFBundleShortVersionString") else { return nil }
    return "inline-apple@\(version)"
  }

  private static func sentryDist() -> String? {
    bundleString(for: "CFBundleVersion")
  }

  private static func sentryCommit() -> String? {
    bundleString(for: "InlineCommit")
  }

  /// Starts Sentry
  public static func start() {
    if debugBuild, !runInDebugBuilds {
      log.trace("Analytics: debug build, skipping start")
      return
    }

    let releaseName = sentryReleaseName()
    let dist = sentryDist()
    let commit = sentryCommit()

    SentrySDK.start { options in
      options.dsn = InlineConfig.SentryDSN
      options.debug = false
      options.tracesSampleRate = 0.1
      options.swiftAsyncStacktraces = true
      options.enableLogs = true
      options.releaseName = releaseName
      options.dist = dist
    }

    SentrySDK.configureScope { scope in
      if let version = bundleString(for: "CFBundleShortVersionString") {
        scope.setTag(value: version, key: "app_version")
      }
      if let dist {
        scope.setTag(value: dist, key: "app_build")
      }
      if let commit {
        scope.setTag(value: commit, key: "app_commit")
      }
    }

    log.info("Analytics: starting")

    // IF AUTHed
    if Auth.shared.getIsLoggedIn() {
      Task {
        log.trace("Analytics: identifying user")
        await Self.identify()
      }
    }
  }

  /// Identifies the user in Sentry by fetching the current user from the database
  public static func identify() async {
    guard let userId = Auth.shared.getCurrentUserId() else { return }

    // Fetch current user from database
    let currentUser = try? await AppDatabase.shared.reader.read { db in
      try User.fetchOne(db, id: userId)
    }

    if let currentUser {
      // All the info
      identify(userId: userId, email: currentUser.email, name: currentUser.fullName, username: currentUser.username)
    } else {
      // Just the ID
      identify(userId: userId, email: nil, name: nil, username: nil)
    }

    log.trace("Analytics: identified user")
  }

  /// Clears the user from Sentry
  public static func logout() {
    SentrySDK.setUser(nil)
    log.trace("Analytics: logged out")
  }

  /// Identifies the user in Sentry
  public static func identify(userId: Int64, email: String?, name: String?, username: String?) {
    let user = Sentry.User()
    user.userId = String(userId)
    user.email = email
    user.name = name
    user.username = username
    SentrySDK.setUser(user)
  }
}

import Auth
import InlineConfig
import Logger
import Sentry

public final class Analytics: Sendable {
  // public static let shared = Analytics()

  private init() {}

  #if DEBUG
  static let debugBuild = true
  #else
  static let debugBuild = false
  #endif

  static let runInDebugBuilds = false

  /// Starts Sentry
  public static func start() {
    if debugBuild, !runInDebugBuilds {
      Log.shared.debug("Analytics: debug build, skipping start")
      return
    }

    SentrySDK.start { options in
      options.dsn = InlineConfig.SentryDSN
      options.debug = false
      options.tracesSampleRate = 0.1
      options.swiftAsyncStacktraces = true
      options.experimental.enableLogs = true
    }

    Log.shared.info("Analytics: starting")

    // IF AUTHed
    if Auth.shared.getIsLoggedIn() {
      Task {
        Log.shared.debug("Analytics: identifying user")
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

    Log.shared.debug("Analytics: identified user")
  }

  /// Clears the user from Sentry
  public static func logout() {
    SentrySDK.setUser(nil)
    Log.shared.debug("Analytics: logged out")
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

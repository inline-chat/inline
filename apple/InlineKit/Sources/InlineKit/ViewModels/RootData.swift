import Combine
import GRDB
import GRDBQuery
import Logger
import Auth

@MainActor
public class RootData: ObservableObject {
  @Published public var currentUserInfo: UserInfo?

  public var currentUser: User? {
    currentUserInfo?.user
  }

  @Published public var error: Subscribers.Completion<any Error>?

  private var fetchedOnce = false

  private var observationCancellable: AnyCancellable?

  private var db: AppDatabase
  private var auth: Auth

  public init(db: AppDatabase, auth: Auth) {
    self.db = db
    self.auth = auth

    let userId = self.auth.getCurrentUserId()

    observationCancellable =
      ValueObservation
        .tracking(
          User
            .userInfoQuery()
            .filter(key: userId)
            .fetchOne
        )
        .publisher(in: db.reader, scheduling: .immediate)
        .sink(
          receiveCompletion: { error in
            self.error = error
          },
          receiveValue: { [weak self] user in
            guard let self else { return }
            currentUserInfo = user

            // Remote fetch
            if user == nil, fetchedOnce == false {
              fetch()
              fetchedOnce = true
            }
          }
        )
  }

  public func fetch() {
    Task { @MainActor in
      do {
        Log.shared.debug("Fetching me")
        let _ = try await DataManager.shared.fetchMe()
        // self.currentUser = user
      } catch {
        Log.shared.error("Error fetching user", error: error)
      }
    }
  }
}

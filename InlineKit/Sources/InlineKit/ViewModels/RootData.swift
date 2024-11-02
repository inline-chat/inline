import Combine
import GRDB
import GRDBQuery

@MainActor
public class RootData: ObservableObject {
    @Published public var currentUser: User?
    @Published public var error: Subscribers.Completion<any Error>?
    
    private var fetchedOnce = false
 
    private var observationCancellable: AnyCancellable?
    
    private var db: AppDatabase
    private var auth: Auth
    
    public init(db: AppDatabase, auth: Auth) {
        self.db = db
        self.auth = auth
        
        let userId = self.auth.getCurrentUserId()
        
        observationCancellable = ValueObservation
            .tracking(User.filter(key: userId).fetchOne)
            .publisher(in: db.reader, scheduling: .immediate)
            .sink(
                receiveCompletion: { error in
                    self.error = error
                },
                receiveValue: { [weak self] user in
                    guard let self = self else { return }
                    self.currentUser = user
                    
                    // Remote fetch
                    if user == nil, fetchedOnce == false {
                        self.fetch()
                        fetchedOnce = true
                    }
                })
    }
    
    public func fetch() {
        Task { @MainActor in
            do {
                Log.shared.debug("Fetching me")
                let result = try await ApiClient.shared.getMe()
                let user = User(from: result.user)
                self.currentUser = user
                try await self.db.dbWriter.write { db in
                    try user.save(db)
                }
            } catch {
                Log.shared.error("Error fetching user", error: error)
            }
        }
    }
}

import Testing

@testable import InlineKit

@MainActor
@Suite("Observation Lifetime")
struct ObservationLifetimeTests {
  @Test("owner-stored observations do not retain retired view models")
  func observationsReleaseTheirOwners() async {
    let database = AppDatabase.empty()

    var participantsModel: ChatParticipantsViewModel? = ChatParticipantsViewModel(
      db: database,
      chatId: 41
    )
    var mediaModel: ChatMediaViewModel? = ChatMediaViewModel(
      db: database,
      chatId: 42,
      peer: .thread(id: 42)
    )
    var spacesModel: CompactSpaceList? = CompactSpaceList(db: database)

    weak var weakParticipantsModel = participantsModel
    weak var weakMediaModel = mediaModel
    weak var weakSpacesModel = spacesModel

    participantsModel = nil
    mediaModel = nil
    spacesModel = nil

    for _ in 0 ..< 10 {
      guard weakParticipantsModel != nil || weakMediaModel != nil || weakSpacesModel != nil else { break }
      await Task.yield()
    }

    #expect(weakParticipantsModel == nil)
    #expect(weakMediaModel == nil)
    #expect(weakSpacesModel == nil)
  }
}

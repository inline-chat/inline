import Foundation
import GRDB
import InlineProtocol
import Testing
@testable import InlineKit

@Suite("Space member badges")
struct SpaceMemberBadgeTests {
  private func space(pro: Bool = false) -> InlineKit.Space {
    InlineKit.Space(id: 42, name: "Design", date: .now, photoFileUniqueId: "photo-a", photoURL: "https://example.com/a.png", isPro: pro)
  }

  @Test("requires confirmed Pro status and excludes guests and nonmembers in every build")
  func strictEligibility() {
    var space = space()
    var member = Member(id: 3, date: .now, userId: 7, spaceId: 42, role: .member)
    #expect(!SpaceMemberBadgePolicy.isEligible(space: space, member: member))
    space.isPro = true
    #expect(SpaceMemberBadgePolicy.isEligible(space: space, member: member))
    member.canAccessPublicChats = false
    #expect(!SpaceMemberBadgePolicy.isEligible(space: space, member: member))
    member.canAccessPublicChats = true
    member.spaceId = 99
    #expect(!SpaceMemberBadgePolicy.isEligible(space: space, member: member))
  }

  @Test("every member role requires Pro and a complete picture")
  func roleEligibility() {
    for role in [MemberRole.owner, .admin, .member] {
      let member = Member(id: 3, date: .now, userId: 7, spaceId: 42, role: role)
      var space = space(pro: true)
      #expect(SpaceMemberBadgePolicy.isEligible(space: space, member: member))
      space.isPro = false
      #expect(!SpaceMemberBadgePolicy.isEligible(space: space, member: member))
      space.isPro = true
      space.photoFileUniqueId = nil
      #expect(!SpaceMemberBadgePolicy.isEligible(space: space, member: member))
      space.photoFileUniqueId = "photo-a"
      space.photoURL = nil
      #expect(!SpaceMemberBadgePolicy.isEligible(space: space, member: member))
    }
  }

  @Test("the new picture fields survive protocol and database round trips")
  func persistence() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    let protocolSpace = InlineProtocol.Space.with {
      $0.id = 42
      $0.name = "Design"
      $0.photoFileUniqueID = "photo-a"
      $0.photoURL = "https://example.com/a.png"
      $0.isPro = true
    }
    let space = InlineKit.Space(from: protocolSpace)
    try queue.write { db in
      try space.save(db)
      let stored = try #require(try InlineKit.Space.fetchOne(db, key: 42))
      #expect(stored.photoFileUniqueId == "photo-a")
      #expect(stored.photoURL == "https://example.com/a.png")
      #expect(stored.isPro)
    }
    #expect(InlineKit.Space(from: InlineProtocol.Space()).photoURL == nil)
  }
  @Test("a removal clears the picture and stale updates cannot restore it")
  func removalAndStaleReplay() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let initial = space(pro: true)
    try await queue.write { db in try initial.save(db) }
    let engine = UpdatesEngine(database: database)
    let removal = InlineProtocol.Update.with {
      $0.seq = 3
      $0.date = 10
      $0.update = .spaceProfile(.with { $0.spaceID = 42; $0.isPro = true })
    }
    #expect(await engine.applyBatch(updates: [removal]).succeeded)
    let stale = InlineProtocol.Update.with {
      $0.seq = 2
      $0.date = 9
      $0.update = .spaceProfile(.with {
        $0.spaceID = 42
        $0.photoFileUniqueID = "old-photo"
        $0.photoURL = "https://example.com/old.png"
        $0.isPro = true
      })
    }
    #expect(await engine.applyBatch(updates: [stale]).succeeded)
    try await queue.read { db in
      let space = try #require(try InlineKit.Space.fetchOne(db, key: 42))
      #expect(space.photoFileUniqueId == nil)
      #expect(space.photoURL == nil)
      #expect(space.seq == 3)
    }
  }

  @Test("a member becoming a guest removes an already visible badge")
  @MainActor
  func observesGuestConversion() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let initial = space(pro: true)
    try await queue.write { db in
      try initial.save(db)
      try InlineKit.User(id: 7, email: nil, firstName: "Member").save(db)
      try Member(id: 3, date: .now, userId: 7, spaceId: 42, role: .member).save(db)
    }
    let model = SpaceMemberBadgeViewModel(db: database, userID: 7, spaceID: 42)
    for _ in 0 ..< 100 where model.space == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.space?.id == 42)
    try await queue.write { db in
      try db.execute(sql: "UPDATE member SET canAccessPublicChats = 0 WHERE id = 3")
    }
    for _ in 0 ..< 100 where model.space != nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.space == nil)
  }

  @Test("a Pro downgrade hides the badge and an upgrade restores it")
  @MainActor
  func observesPlanChanges() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let initial = space(pro: true)
    try await queue.write { db in
      try initial.save(db)
      try InlineKit.User(id: 7, email: nil, firstName: "Member").save(db)
      try Member(id: 3, date: .now, userId: 7, spaceId: 42, role: .member).save(db)
    }
    let model = SpaceMemberBadgeViewModel(db: database, userID: 7, spaceID: 42)
    for _ in 0 ..< 100 where model.space == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.space?.id == 42)

    let engine = UpdatesEngine(database: database)
    for (sequence, isPro) in [(1, false), (2, true)] {
      let update = InlineProtocol.Update.with {
        $0.seq = Int32(sequence)
        $0.date = 10
        $0.update = .spaceProfile(.with {
          $0.spaceID = 42
          $0.photoFileUniqueID = "photo-a"
          $0.photoURL = "https://example.com/a.png"
          $0.isPro = isPro
        })
      }
      #expect(await engine.applyBatch(updates: [update]).succeeded)
      for _ in 0 ..< 100 where (model.space != nil) != isPro {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect((model.space != nil) == isPro)
    }
  }

  @Test("removing a picture or membership hides an existing badge")
  @MainActor
  func observesPhotoAndMembershipRemoval() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let initial = space(pro: true)
    try await queue.write { db in
      try initial.save(db)
      try InlineKit.User(id: 7, email: nil, firstName: "Member").save(db)
      try Member(id: 3, date: .now, userId: 7, spaceId: 42, role: .member).save(db)
    }
    let model = SpaceMemberBadgeViewModel(db: database, userID: 7, spaceID: 42)
    for _ in 0 ..< 100 where model.space == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.space?.id == 42)
    try await queue.write { db in
      var removed = initial
      removed.photoFileUniqueId = nil
      removed.photoURL = nil
      try removed.save(db)
    }
    for _ in 0 ..< 100 where model.space != nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.space == nil)
    try await queue.write { db in try initial.save(db) }
    for _ in 0 ..< 100 where model.space == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.space?.id == 42)
    try await queue.write { db in _ = try Member.deleteOne(db, key: 3) }
    for _ in 0 ..< 100 where model.space != nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.space == nil)
  }


  @Test("without a space in context, the earliest Pro space joined as a full member with a photo")
  func affiliation() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    try queue.write { db in
      try InlineKit.User(id: 7, email: nil, firstName: "Member").save(db)
      let free = InlineKit.Space(id: 10, name: "Free", date: .now, photoFileUniqueId: "f", photoURL: "https://example.com/f.png", isPro: false)
      let guestPro = InlineKit.Space(id: 11, name: "Guest", date: .now, photoFileUniqueId: "g", photoURL: "https://example.com/g.png", isPro: true)
      let team = InlineKit.Space(id: 12, name: "Team", date: .now, photoFileUniqueId: "t", photoURL: "https://example.com/t.png", isPro: true)
      let later = InlineKit.Space(id: 13, name: "Later", date: .now, photoFileUniqueId: "l", photoURL: "https://example.com/l.png", isPro: true)
      for space in [free, guestPro, team, later] { try space.save(db) }
      try Member(id: 1, date: Date(timeIntervalSince1970: 1), userId: 7, spaceId: 10, role: .member).save(db)
      var guest = Member(id: 2, date: Date(timeIntervalSince1970: 2), userId: 7, spaceId: 11, role: .member)
      guest.canAccessPublicChats = false
      try guest.save(db)
      try Member(id: 4, date: Date(timeIntervalSince1970: 4), userId: 7, spaceId: 13, role: .member).save(db)
      try Member(id: 3, date: Date(timeIntervalSince1970: 3), userId: 7, spaceId: 12, role: .member).save(db)
      #expect(try SpaceMemberBadgePolicy.affiliation(db, userID: 7)?.id == 12)
      #expect(try SpaceMemberBadgePolicy.affiliation(db, userID: 8) == nil)
    }
  }

  @Test("team plans list every Pro space covering a full member in join order, photo or not")
  func teamPlans() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    try queue.write { db in
      try InlineKit.User(id: 7, email: nil, firstName: "Member").save(db)
      let bare = InlineKit.Space(id: 20, name: "Bare", date: .now, isPro: true)
      let free = InlineKit.Space(id: 21, name: "Free", date: .now, isPro: false)
      let guestPro = InlineKit.Space(id: 22, name: "Guest", date: .now, isPro: true)
      let team = InlineKit.Space(id: 23, name: "Team", date: .now, photoFileUniqueId: "t", photoURL: "https://example.com/t.png", isPro: true)
      for space in [bare, free, guestPro, team] { try space.save(db) }
      try Member(id: 1, date: Date(timeIntervalSince1970: 1), userId: 7, spaceId: 20, role: .member).save(db)
      try Member(id: 2, date: Date(timeIntervalSince1970: 2), userId: 7, spaceId: 21, role: .member).save(db)
      var guest = Member(id: 3, date: Date(timeIntervalSince1970: 3), userId: 7, spaceId: 22, role: .member)
      guest.canAccessPublicChats = false
      try guest.save(db)
      try Member(id: 4, date: Date(timeIntervalSince1970: 4), userId: 7, spaceId: 23, role: .member).save(db)
      #expect(try SpaceMemberBadgePolicy.teamPlans(db, userID: 7).map(\.id) == [20, 23])
      // The affiliation badge skips the team without a photo.
      #expect(try SpaceMemberBadgePolicy.affiliation(db, userID: 7)?.id == 23)
      #expect(try SpaceMemberBadgePolicy.teamPlans(db, userID: 8).isEmpty)
    }
  }

  @Test("the user badge survives protocol saves, min ones included, and clears when removed")
  func userBadgePersistence() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    try queue.write { db in
      let believer = InlineProtocol.User.with {
        $0.id = 7
        $0.firstName = "Mo"
        $0.badge = .with { $0.kind = .believer }
      }
      #expect(try InlineKit.User.save(db, user: believer).badge == .believer)
      #expect(try InlineKit.User.fetchOne(db, id: 7)?.badge == .believer)
      let minPro = InlineProtocol.User.with {
        $0.id = 7
        $0.min = true
        $0.badge = .with { $0.kind = .pro }
      }
      _ = try InlineKit.User.save(db, user: minPro)
      #expect(try InlineKit.User.fetchOne(db, id: 7)?.badge == .pro)
      _ = try InlineKit.User.save(db, user: .with { $0.id = 7; $0.min = true })
      #expect(try InlineKit.User.fetchOne(db, id: 7)?.badge == nil)
      let unknown = InlineProtocol.User.with { $0.id = 7; $0.badge = .with { $0.kind = .UNRECOGNIZED(9) } }
      #expect(try InlineKit.User.save(db, user: unknown).badge == nil)
    }
  }
}

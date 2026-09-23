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

}

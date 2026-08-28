import Foundation
import GRDB
import Testing

@testable import InlineKit

@Suite("Invite directory")
struct InviteDirectoryTests {
  @Test("local search matches people and chatted bots by display name")
  func localSearchIncludesChattedBots() async throws {
    let database = AppDatabase.empty()
    try await database.dbWriter.write { db in
      var matchingPerson = User(
        id: 9,
        email: nil,
        firstName: "Release",
        lastName: "Human",
        username: "releasehuman"
      )
      matchingPerson.pendingSetup = false
      try matchingPerson.insert(db)

      var person = User(id: 10, email: nil, firstName: "Ada", lastName: "Lovelace", username: "ada")
      person.pendingSetup = false
      try person.insert(db)

      var chattedBot = User(
        id: 11,
        email: nil,
        firstName: "Release",
        lastName: "Helper",
        username: "deploybot"
      )
      chattedBot.pendingSetup = false
      chattedBot.bot = true
      try chattedBot.insert(db)
      try Chat(
        id: 101,
        date: Date(timeIntervalSince1970: 1),
        type: .privateChat,
        title: nil,
        spaceId: nil,
        peerUserId: chattedBot.id
      ).insert(db)

      var unknownBot = User(
        id: 12,
        email: nil,
        firstName: "Release",
        lastName: "Stranger",
        username: "strangerbot"
      )
      unknownBot.pendingSetup = false
      unknownBot.bot = true
      try unknownBot.insert(db)

      var pendingBot = User(
        id: 13,
        email: nil,
        firstName: "Release",
        lastName: "Pending",
        username: "pendingbot"
      )
      pendingBot.pendingSetup = true
      pendingBot.bot = true
      try pendingBot.insert(db)
      try Chat(
        id: 102,
        date: Date(timeIntervalSince1970: 2),
        type: .privateChat,
        title: nil,
        spaceId: nil,
        peerUserId: pendingBot.id
      ).insert(db)

      var literalUser = User(
        id: 14,
        email: nil,
        firstName: "Literal",
        lastName: "Under",
        username: "literal_under"
      )
      literalUser.pendingSetup = false
      try literalUser.insert(db)

      var wildcardNeighbor = User(
        id: 15,
        email: nil,
        firstName: "Literal",
        lastName: "Neighbor",
        username: "literalXunder"
      )
      wildcardNeighbor.pendingSetup = false
      try wildcardNeighbor.insert(db)
    }

    let people = try await InviteDirectory.localUsers(query: "v", database: database)
    #expect(people.map(\.id) == [10])

    let bots = try await InviteDirectory.localUsers(query: "release", database: database)
    #expect(bots.map(\.id) == [11, 9])

    let limited = try await InviteDirectory.localUsers(query: "release", database: database, limit: 1)
    #expect(limited.map(\.id) == [11])

    let leadingAtSign = try await InviteDirectory.localUsers(query: "@deploy", database: database)
    #expect(leadingAtSign.map(\.id) == [11])

    let unrelatedBot = try await InviteDirectory.localUsers(query: "strangerbot", database: database)
    #expect(unrelatedBot.isEmpty)

    let literal = try await InviteDirectory.localUsers(query: "literal_", database: database)
    #expect(literal.map(\.id) == [14])
  }

  @Test("remote eligibility normalizes usernames without sending private-shaped input")
  func remoteSearchEligibility() {
    #expect(!InviteDirectory.remoteSearchIsEligible(query: "a"))
    #expect(!InviteDirectory.remoteSearchIsEligible(query: "@a"))
    #expect(InviteDirectory.remoteSearchIsEligible(query: "ab"))
    #expect(InviteDirectory.remoteSearchIsEligible(query: "@ab"))
    #expect(!InviteDirectory.remoteSearchIsEligible(query: "person@example.com"))
    #expect(!InviteDirectory.remoteSearchIsEligible(query: "+12025550123"))
  }

  @Test("in-memory matching handles names, usernames, email scope, and a bare at sign")
  func localUserMatching() {
    let info = UserInfo(
      user: User(
        id: 19,
        email: "release@example.com",
        firstName: "Release",
        lastName: "Helper",
        username: "deploybot"
      )
    )

    #expect(InviteDirectory.localUserMatches(info, query: "helper"))
    #expect(InviteDirectory.localUserMatches(info, query: "@deploy"))
    #expect(InviteDirectory.localUserMatches(info, query: ""))
    #expect(!InviteDirectory.localUserMatches(info, query: "@"))
    #expect(!InviteDirectory.localUserMatches(info, query: "example.com"))
    #expect(InviteDirectory.localUserMatches(info, query: "example.com", includeEmail: true))
  }

  @Test("merge keeps local order and identity while excluding participants")
  func mergeKeepsLocalPrecedence() {
    let local = [
      UserInfo(user: User(id: 20, email: nil, firstName: "Local", username: "local")),
      UserInfo(user: User(id: 21, email: nil, firstName: "Excluded", username: "excluded")),
    ]
    let remote = [
      UserInfo(user: User(id: 20, email: nil, firstName: "Duplicate", username: "local")),
      UserInfo(user: User(id: 22, email: nil, firstName: "Remote", username: "remote")),
    ]

    let merged = InviteDirectory.mergedUsers(
      local: local,
      remote: remote,
      excluding: [21],
      limit: 2
    )

    #expect(merged.map(\.id) == [20, 22])
    #expect(merged.first?.user.firstName == "Local")
    #expect(InviteDirectory.mergedUsers(local: local, remote: remote, limit: 0).isEmpty)
  }
}

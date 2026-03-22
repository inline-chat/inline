import Foundation
import InlineProtocol
import Testing
@testable import InlineKit

@MainActor
@Suite("Peer Bot Commands ViewModel")
struct PeerBotCommandsViewModelTests {
  @Test("loads once per peer and reuses cached results")
  func cachesPerPeer() async {
    let counter = FetchCounter()
    let threadPeer = Peer.thread(id: 100)
    let otherPeer = Peer.thread(id: 200)

    let viewModel = PeerBotCommandsViewModel(peer: threadPeer) { peer in
      await counter.increment()
      if peer == threadPeer {
        return [Self.makeGroup(botId: 1, username: "alpha", commands: [("help", "Show help")])]
      }
      return [Self.makeGroup(botId: 2, username: "beta", commands: [("start", "Start bot")])]
    }

    await viewModel.ensureLoaded()
    await viewModel.ensureLoaded()
    #expect(await counter.value == 1)
    #expect(viewModel.botGroups.count == 1)

    viewModel.setPeer(otherPeer)
    await viewModel.ensureLoaded()
    #expect(await counter.value == 2)
    #expect(viewModel.botGroups.first?.bot.username == "beta")

    viewModel.setPeer(threadPeer)
    await viewModel.ensureLoaded()
    #expect(await counter.value == 2)
    #expect(viewModel.botGroups.first?.bot.username == "alpha")
  }

  @Test("marks duplicate commands case-insensitively and builds targeted insertion text")
  func marksAmbiguousSuggestions() async {
    let peer = Peer.thread(id: 100)
    let viewModel = PeerBotCommandsViewModel(peer: peer) { _ in
      [
        Self.makeGroup(botId: 1, username: "alpha", commands: [("help", "Alpha help")]),
        Self.makeGroup(botId: 2, username: "beta", commands: [("help", "Beta help")]),
      ]
    }

    await viewModel.ensureLoaded()
    let suggestions = viewModel.suggestions(matching: "he")

    #expect(suggestions.count == 2)
    #expect(suggestions.allSatisfy { $0.isAmbiguous })
    #expect(suggestions.map(\.insertionText) == ["/help@alpha ", "/help@beta "])
  }

  @Test("filters by command, description, and bot username fragments")
  func filtersSuggestions() async {
    let peer = Peer.thread(id: 100)
    let viewModel = PeerBotCommandsViewModel(peer: peer) { _ in
      [
        Self.makeGroup(
          botId: 1,
          username: "alpha",
          commands: [("deploy", "Deploy the app"), ("logs", "View deploy logs")]
        ),
        Self.makeGroup(
          botId: 2,
          username: "buildbot",
          commands: [("build", "Run a build")]
        ),
      ]
    }

    await viewModel.ensureLoaded()

    #expect(viewModel.suggestions(matching: "build").map(\.command) == ["build"])
    #expect(viewModel.suggestions(matching: "deploy logs").map(\.command) == ["logs"])
    #expect(viewModel.suggestions(matching: "build@build").map(\.command) == ["build"])
  }

  @Test("retries after a failed load")
  func retriesAfterFailure() async {
    let peer = Peer.thread(id: 100)
    let counter = FetchCounter()
    let viewModel = PeerBotCommandsViewModel(peer: peer) { _ in
      let attempt = await counter.next()
      if attempt == 1 {
        struct TestError: Error {}
        throw TestError()
      }
      return [Self.makeGroup(botId: 1, username: "alpha", commands: [("help", "Show help")])]
    }

    await viewModel.ensureLoaded()
    #expect(viewModel.shouldAttemptLoad)

    await viewModel.ensureLoaded()
    #expect(await counter.value == 2)
    #expect(viewModel.loadState == .loaded)
    #expect(viewModel.suggestions.map(\.command) == ["help"])
  }

  @Test("uses resolver hydrated bot user info")
  func usesResolverHydratedUserInfo() async throws {
    let peer = Peer.thread(id: 100)
    let cachedPath = "avatars/bot-1.jpg"

    let viewModel = PeerBotCommandsViewModel(
      peer: peer,
      fetcher: { _ in
        [Self.makeGroup(botId: 1, username: "alpha", commands: [("help", "Show help")])]
      },
      userInfoResolver: { botId, _ in
        var cachedUser = User(
          id: botId,
          email: nil,
          firstName: "Cached",
          username: "alpha"
        )
        cachedUser.profileLocalPath = cachedPath
        return UserInfo(user: cachedUser)
      }
    )

    await viewModel.ensureLoaded()
    let suggestion = try #require(viewModel.suggestions.first)
    #expect(suggestion.botUserInfo.user.profileLocalPath == cachedPath)
  }

  private nonisolated static func makeGroup(
    botId: Int64,
    username: String,
    commands: [(String, String)]
  ) -> PeerBotCommands {
    var bot = User()
    bot.id = botId
    bot.username = username
    bot.firstName = username.capitalized

    var group = PeerBotCommands()
    group.bot = bot
    group.commands = commands.map { command, description in
      var item = BotCommand()
      item.command = command
      item.description_p = description
      return item
    }
    return group
  }
}

private actor FetchCounter {
  private(set) var value = 0

  func increment() {
    value += 1
  }

  func next() -> Int {
    value += 1
    return value
  }
}

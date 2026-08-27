import Foundation
import InlineProtocol
import Testing
@testable import InlineKit

@MainActor
@Suite("Peer Bot Commands ViewModel")
struct PeerBotCommandsViewModelTests {
  private nonisolated static func makeResolver() -> PeerBotCommandsViewModel.UserInfoResolver {
    { _, user in
      UserInfo(user: User(from: user))
    }
  }

  @Test("loads once per peer and reuses cached results")
  func cachesPerPeer() async {
    let counter = FetchCounter()
    let threadPeer = Peer.thread(id: 100)
    let otherPeer = Peer.thread(id: 200)

    let viewModel = PeerBotCommandsViewModel(
      peer: threadPeer,
      fetcher: { peer in
        await counter.increment()
        if peer == threadPeer {
          return [Self.makeGroup(botId: 1, username: "alpha", commands: [("help", "Show help")])]
        }
        return [Self.makeGroup(botId: 2, username: "beta", commands: [("start", "Start bot")])]
      },
      userInfoResolver: Self.makeResolver()
    )

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

  @Test("concurrent callers wait for the same initial load")
  func concurrentCallersWaitForInitialLoad() async {
    let gate = AsyncGate()
    let completion = AsyncFlag()
    let counter = FetchCounter()
    let viewModel = PeerBotCommandsViewModel(
      peer: .thread(id: 100),
      fetcher: { _ in
        await counter.increment()
        await gate.wait()
        return [Self.makeGroup(botId: 1, username: "alpha", commands: [("help", "Show help")])]
      },
      userInfoResolver: Self.makeResolver()
    )

    let first = Task { @MainActor in
      await viewModel.ensureLoaded()
    }
    while viewModel.loadState != .loading {
      await Task.yield()
    }
    let second = Task { @MainActor in
      await viewModel.ensureLoaded()
      await completion.set()
    }

    await Task.yield()
    #expect(await completion.value == false)
    #expect(await counter.value == 1)

    await gate.open()
    await first.value
    await second.value

    #expect(await completion.value)
    #expect(viewModel.loadState == .loaded)
    #expect(viewModel.suggestions.map(\.command) == ["help"])
  }

  @Test("a superseded load cannot overwrite the refreshed cache")
  func supersededLoadCannotOverwriteRefreshedCache() async {
    let firstLoadGate = AsyncGate()
    let counter = FetchCounter()
    let peer = Peer.thread(id: 100)
    let otherPeer = Peer.thread(id: 200)
    let viewModel = PeerBotCommandsViewModel(
      peer: peer,
      fetcher: { _ in
        let attempt = await counter.next()
        if attempt == 1 {
          await firstLoadGate.wait()
          return [Self.makeGroup(botId: 1, username: "old", commands: [("old", "Old result")])]
        }
        return [Self.makeGroup(botId: 2, username: "new", commands: [("new", "New result")])]
      },
      userInfoResolver: Self.makeResolver()
    )

    let initialLoad = Task { @MainActor in
      await viewModel.ensureLoaded()
    }
    while viewModel.loadState != .loading {
      await Task.yield()
    }

    await viewModel.refresh()
    #expect(viewModel.suggestions.map(\.command) == ["new"])

    await firstLoadGate.open()
    await initialLoad.value
    #expect(viewModel.suggestions.map(\.command) == ["new"])

    viewModel.setPeer(otherPeer)
    viewModel.setPeer(peer)
    #expect(viewModel.suggestions.map(\.command) == ["new"])
    #expect(await counter.value == 2)
  }

  @Test("ensure loaded waits for an in-flight refresh instead of restoring stale cache")
  func ensureLoadedWaitsForRefresh() async {
    let refreshGate = AsyncGate()
    let completion = AsyncFlag()
    let counter = FetchCounter()
    let viewModel = PeerBotCommandsViewModel(
      peer: .thread(id: 100),
      fetcher: { _ in
        let attempt = await counter.next()
        if attempt == 1 {
          return [Self.makeGroup(botId: 1, username: "old", commands: [("old", "Old result")])]
        }
        await refreshGate.wait()
        return [Self.makeGroup(botId: 2, username: "new", commands: [("new", "New result")])]
      },
      userInfoResolver: Self.makeResolver()
    )

    await viewModel.ensureLoaded()
    let refresh = Task { @MainActor in
      await viewModel.refresh()
    }
    while viewModel.loadState != .loading {
      await Task.yield()
    }

    let concurrentLoad = Task { @MainActor in
      await viewModel.ensureLoaded()
      await completion.set()
    }
    await Task.yield()

    #expect(await completion.value == false)
    #expect(viewModel.loadState == .loading)

    await refreshGate.open()
    await refresh.value
    await concurrentLoad.value

    #expect(await completion.value)
    #expect(viewModel.suggestions.map(\.command) == ["new"])
    #expect(await counter.value == 2)
  }

  @Test("marks duplicate commands case-insensitively and builds targeted insertion text")
  func marksAmbiguousSuggestions() async {
    let peer = Peer.thread(id: 100)
    let viewModel = PeerBotCommandsViewModel(
      peer: peer,
      fetcher: { _ in
        [
          Self.makeGroup(botId: 1, username: "alpha", commands: [("help", "Alpha help")]),
          Self.makeGroup(botId: 2, username: "beta", commands: [("help", "Beta help")]),
        ]
      },
      userInfoResolver: Self.makeResolver()
    )

    await viewModel.ensureLoaded()
    let suggestions = viewModel.suggestions(matching: "he")

    #expect(suggestions.count == 2)
    #expect(suggestions.allSatisfy { $0.isAmbiguous })
    #expect(suggestions.map(\.insertionText) == ["/help@alpha ", "/help@beta "])
  }

  @Test("keeps commands visually clean when multiple bots do not conflict")
  func keepsUnambiguousSuggestionClean() async {
    let viewModel = PeerBotCommandsViewModel(
      peer: .thread(id: 100),
      fetcher: { _ in
        [
          Self.makeGroup(botId: 1, username: "alpha", commands: [("help", "Show help")]),
          Self.makeGroup(botId: 2, username: "beta", commands: [("logs", "Show logs")]),
        ]
      },
      userInfoResolver: Self.makeResolver()
    )

    await viewModel.ensureLoaded()
    #expect(viewModel.suggestions.allSatisfy { !$0.isAmbiguous })
    #expect(viewModel.suggestions.map(\.insertionText) == ["/help ", "/logs "])
  }

  @Test("filters by command, description, and bot username fragments")
  func filtersSuggestions() async {
    let peer = Peer.thread(id: 100)
    let viewModel = PeerBotCommandsViewModel(
      peer: peer,
      fetcher: { _ in
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
      },
      userInfoResolver: Self.makeResolver()
    )

    await viewModel.ensureLoaded()

    #expect(viewModel.suggestions(matching: "build").map(\.command) == ["build"])
    #expect(viewModel.suggestions(matching: "deploy logs").map(\.command) == ["logs"])
    #expect(viewModel.suggestions(matching: "build@build").map(\.command) == ["build"])
  }

  @Test("retries after a failed load")
  func retriesAfterFailure() async {
    let peer = Peer.thread(id: 100)
    let counter = FetchCounter()
    let viewModel = PeerBotCommandsViewModel(
      peer: peer,
      fetcher: { _ in
        let attempt = await counter.next()
        if attempt == 1 {
          struct TestError: Error {}
          throw TestError()
        }
        return [Self.makeGroup(botId: 1, username: "alpha", commands: [("help", "Show help")])]
      },
      userInfoResolver: Self.makeResolver()
    )

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

  @Test("Agent directory caches access-filtered profiles per peer")
  func agentDirectoryCachesPerPeer() async throws {
    let counter = FetchCounter()
    let peer = Peer.thread(id: 100)
    let directory = BotAgentDirectory(
      fetcher: { requestedPeer in
        #expect(requestedPeer == peer)
        await counter.increment()
        var bot = User()
        bot.id = 200
        bot.firstName = "Research Bot"
        var profile = BotAgentProfile()
        profile.id = 7
        profile.botUserID = 200
        profile.name = "Data Analyst"
        profile.emoji = "📊"
        var peerBot = PeerBot()
        peerBot.bot = bot
        peerBot.agents = [profile]
        var result = GetPeerBotsResult()
        result.bots = [peerBot]
        return result
      },
      userInfoResolver: { UserInfo(user: User(from: $0)) }
    )

    let first = try await directory.agents(for: peer)
    let second = try await directory.agents(for: peer)

    #expect(await counter.value == 1)
    #expect(first == second)
    #expect(first.first?.id == 7)
    #expect(first.first?.botUserId == 200)
    #expect(directory.cached(agentId: 7, botUserId: 200, for: peer)?.name == "Data Analyst")
    #expect(directory.cached(agentId: 7, botUserId: 201, for: peer) == nil)
    #expect(directory.cached(agentId: 7, botUserId: 200, for: .thread(id: 101)) == nil)
  }

  @Test("Agent directory skips discovery when the client experiment is off")
  func agentDirectoryHonorsClientExperiment() async throws {
    let counter = FetchCounter()
    let directory = BotAgentDirectory(
      fetcher: { _ in
        await counter.increment()
        return GetPeerBotsResult()
      },
      userInfoResolver: { UserInfo(user: User(from: $0)) },
      isEnabled: { false }
    )

    #expect(try await directory.agents(for: .thread(id: 100)).isEmpty)
    #expect(await counter.value == 0)
    #expect(directory.cached(agentId: 7, botUserId: 200, for: .thread(id: 100)) == nil)
  }

  @Test("Agent directory expires and bounds peer-scoped profiles")
  func agentDirectoryExpiresAndBoundsProfiles() async throws {
    let counter = FetchCounter()
    var now = Date(timeIntervalSince1970: 1_000)
    let firstPeer = Peer.thread(id: 100)
    let secondPeer = Peer.thread(id: 101)
    let directory = BotAgentDirectory(
      fetcher: { peer in
        await counter.increment()
        return Self.makeAgentDiscoveryResult(agentId: peer == firstPeer ? 7 : 8)
      },
      userInfoResolver: { UserInfo(user: User(from: $0)) },
      now: { now },
      cacheTTL: 60,
      maxCachedPeers: 1
    )

    _ = try await directory.agents(for: firstPeer)
    now.addTimeInterval(61)
    _ = try await directory.agents(for: firstPeer)
    #expect(await counter.value == 2)

    _ = try await directory.agents(for: secondPeer)
    #expect(directory.cached(agentId: 7, botUserId: 200, for: firstPeer) == nil)
    #expect(directory.cached(agentId: 8, botUserId: 200, for: secondPeer) != nil)
  }

  @Test("Agent directory cannot repopulate after account cache clear")
  func agentDirectoryRejectsClearedInFlightResult() async throws {
    let started = AsyncFlag()
    let release = AsyncGate()
    let peer = Peer.thread(id: 100)
    let directory = BotAgentDirectory(
      fetcher: { _ in
        await started.set()
        await release.wait()
        return Self.makeAgentDiscoveryResult(agentId: 7)
      },
      userInfoResolver: { UserInfo(user: User(from: $0)) }
    )

    let fetch = Task { try await directory.agents(for: peer) }
    while !(await started.value) { await Task.yield() }
    directory.clear()
    await release.open()

    #expect(try await fetch.value.isEmpty)
    #expect(directory.cached(agentId: 7, botUserId: 200, for: peer) == nil)
  }

  @Test("Agent directory invalidation replaces an in-flight result")
  func agentDirectoryInvalidationReplacesInFlightResult() async throws {
    let attempts = FetchCounter()
    let started = AsyncFlag()
    let release = AsyncGate()
    let peer = Peer.thread(id: 100)
    let directory = BotAgentDirectory(
      fetcher: { _ in
        let attempt = await attempts.next()
        if attempt == 1 {
          await started.set()
          await release.wait()
          return Self.makeAgentDiscoveryResult(agentId: 7)
        }
        return Self.makeAgentDiscoveryResult(agentId: 8)
      },
      userInfoResolver: { UserInfo(user: User(from: $0)) }
    )

    let staleFetch = Task { try await directory.agents(for: peer) }
    while !(await started.value) { await Task.yield() }
    directory.invalidate(botUserId: 200)

    let replacement = try await directory.agents(for: peer)
    #expect(replacement.first?.id == 8)

    await release.open()
    #expect(try await staleFetch.value.isEmpty)
    #expect(directory.cached(agentId: 8, botUserId: 200, for: peer) != nil)
  }

  private nonisolated static func makeAgentDiscoveryResult(agentId: Int64) -> GetPeerBotsResult {
    var bot = User()
    bot.id = 200
    bot.firstName = "Research Bot"
    var profile = BotAgentProfile()
    profile.id = agentId
    profile.botUserID = 200
    profile.name = "Data Analyst"
    var peerBot = PeerBot()
    peerBot.bot = bot
    peerBot.agents = [profile]
    var result = GetPeerBotsResult()
    result.bots = [peerBot]
    return result
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

private actor AsyncGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func open() {
    isOpen = true
    let currentWaiters = waiters
    waiters.removeAll()
    currentWaiters.forEach { $0.resume() }
  }
}

private actor AsyncFlag {
  private(set) var value = false

  func set() {
    value = true
  }
}

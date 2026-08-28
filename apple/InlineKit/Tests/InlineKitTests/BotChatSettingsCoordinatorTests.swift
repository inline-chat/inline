@testable import InlineKit
import Foundation
import InlineProtocol
import Testing

@Suite("Bot chat settings coordinator", .serialized)
@MainActor
struct BotChatSettingsCoordinatorTests {
  @Test("selects the suggested V1 bot and loads its document")
  func discoveryAndWarmUp() async {
    let coordinator = BotChatSettingsCoordinator(
      peer: .thread(id: 77),
      discoveryFetcher: { _ in discoveryResult() },
      settingsRequester: { _, _ in documentResponse(revision: "one") },
      itemInvoker: { _, _, _, _, _ in documentResponse(revision: "two", following: true) }
    )

    await coordinator.warmUp()
    await waitUntil { coordinator.selectedState.phase == .loaded }

    #expect(coordinator.bots.map(\.id) == [10, 20])
    #expect(coordinator.selectedBotID == 20)
    #expect(coordinator.selectedState.document?.revision == "one")
  }

  @Test("preserves manual selection across rediscovery")
  func preservesSelection() async {
    let coordinator = BotChatSettingsCoordinator(
      peer: .thread(id: 77),
      discoveryFetcher: { _ in discoveryResult() },
      settingsRequester: { _, _ in documentResponse(revision: "one") },
      itemInvoker: { _, _, _, _, _ in documentResponse(revision: "two", following: true) }
    )
    await coordinator.warmUp()
    await waitUntil { coordinator.selectedState.phase == .loaded }
    coordinator.selectBot(10)
    await waitUntil { coordinator.selectedBotID == 10 }

    coordinator.invalidateDiscovery()
    await waitUntil { !coordinator.isDiscovering }

    #expect(coordinator.selectedBotID == 10)
  }

  @Test("retries an empty discovery result for late capability registration")
  func retriesLateCapability() async {
    let discoveries = DiscoverySequence()
    let coordinator = BotChatSettingsCoordinator(
      peer: .user(id: 20),
      discoveryFetcher: { _ in await discoveries.next() },
      settingsRequester: { _, _ in documentResponse(revision: "one") },
      itemInvoker: { _, _, _, _, _ in documentResponse(revision: "two", following: true) },
      retryDelays: [.milliseconds(1)]
    )

    await coordinator.warmUp()
    await waitUntil { coordinator.selectedState.phase == .loaded }

    #expect(await discoveries.count == 2)
    #expect(coordinator.isToolbarVisible)
    #expect(coordinator.selectedBotID == 20)
  }

  @Test("applies changes immediately and coalesces repeated changes")
  func optimisticCoalescedMutation() async {
    let gate = MutationGate()
    let coordinator = BotChatSettingsCoordinator(
      peer: .thread(id: 77),
      discoveryFetcher: { _ in discoveryResult() },
      settingsRequester: { _, _ in documentResponse(revision: "one", replyThreads: "auto") },
      itemInvoker: { _, _, itemID, value, revision in
        await gate.invoke(itemID: itemID, value: value, revision: revision)
      }
    )
    await coordinator.warmUp()
    await waitUntil { coordinator.selectedState.phase == .loaded }

    coordinator.invoke(itemID: "reply-threads", value: .string("on"))
    await waitUntilAsync { await gate.count == 1 }
    #expect(replyThreadsValue(in: coordinator.selectedState.document) == "on")
    #expect(coordinator.selectedState.pendingItemIDs == ["reply-threads"])

    coordinator.invoke(itemID: "reply-threads", value: .string("off"))
    coordinator.invoke(itemID: "reply-threads", value: .string("auto"))
    #expect(replyThreadsValue(in: coordinator.selectedState.document) == "auto")
    #expect(await gate.count == 1)

    await gate.resolveNext(with: documentResponse(revision: "two", replyThreads: "on"))
    await waitUntilAsync { await gate.count == 2 }
    #expect(await gate.call(at: 1) == .init(
      itemID: "reply-threads",
      value: .string("auto"),
      revision: "two"
    ))
    #expect(replyThreadsValue(in: coordinator.selectedState.document) == "auto")

    await gate.resolveNext(with: documentResponse(revision: "three", replyThreads: "auto"))
    await waitUntil { coordinator.isMutating == false }

    #expect(await gate.count == 2)
    #expect(coordinator.selectedState.document?.revision == "three")
    #expect(replyThreadsValue(in: coordinator.selectedState.document) == "auto")
    #expect(coordinator.selectedState.pendingItemIDs.isEmpty)
    #expect(coordinator.selectedState.problem == nil)
  }

  @Test("rebases one stale mutation without surfacing an error")
  func staleMutationRebase() async {
    let gate = MutationGate()
    let coordinator = BotChatSettingsCoordinator(
      peer: .thread(id: 77),
      discoveryFetcher: { _ in discoveryResult() },
      settingsRequester: { _, _ in documentResponse(revision: "one", replyThreads: "auto") },
      itemInvoker: { _, _, itemID, value, revision in
        await gate.invoke(itemID: itemID, value: value, revision: revision)
      }
    )
    await coordinator.warmUp()
    await waitUntil { coordinator.selectedState.phase == .loaded }

    coordinator.invoke(itemID: "reply-threads", value: .string("on"))
    await waitUntilAsync { await gate.count == 1 }
    await gate.resolveNext(with: staleResponse(revision: "server-two", replyThreads: "auto"))
    await waitUntilAsync { await gate.count == 2 }

    #expect(await gate.call(at: 1)?.revision == "server-two")
    #expect(replyThreadsValue(in: coordinator.selectedState.document) == "on")
    #expect(coordinator.selectedState.problem == nil)

    await gate.resolveNext(with: documentResponse(revision: "three", replyThreads: "on"))
    await waitUntil { coordinator.isMutating == false }

    #expect(coordinator.selectedState.document?.revision == "three")
    #expect(replyThreadsValue(in: coordinator.selectedState.document) == "on")
    #expect(coordinator.selectedState.problem == nil)
  }

  @Test("retries one transient mutation transport failure")
  func transientMutationRetry() async {
    let invocations = TransientMutationSequence()
    let coordinator = BotChatSettingsCoordinator(
      peer: .thread(id: 77),
      discoveryFetcher: { _ in discoveryResult() },
      settingsRequester: { _, _ in documentResponse(revision: "one", replyThreads: "auto") },
      itemInvoker: { _, _, _, _, _ in try await invocations.invoke() },
      transientMutationRetryDelay: .milliseconds(0)
    )
    await coordinator.warmUp()
    await waitUntil { coordinator.selectedState.phase == .loaded }

    coordinator.invoke(itemID: "reply-threads", value: .string("on"))
    await waitUntil { coordinator.isMutating == false }

    #expect(await invocations.count == 2)
    #expect(coordinator.selectedState.document?.revision == "two")
    #expect(replyThreadsValue(in: coordinator.selectedState.document) == "on")
    #expect(coordinator.selectedState.problem == nil)
  }

  @Test("preserves an actionable mutation transport error after rollback")
  func mutationTransportErrorPresentation() async {
    let invocations = FailedMutationSequence()
    let coordinator = BotChatSettingsCoordinator(
      peer: .thread(id: 77),
      discoveryFetcher: { _ in discoveryResult() },
      settingsRequester: { _, _ in documentResponse(revision: "one", replyThreads: "auto") },
      itemInvoker: { _, _, _, _, _ in try await invocations.invoke() },
      transientMutationRetryDelay: .milliseconds(0)
    )
    await coordinator.warmUp()
    await waitUntil { coordinator.selectedState.phase == .loaded }

    coordinator.invoke(itemID: "reply-threads", value: .string("on"))
    await waitUntil { coordinator.isMutating == false }

    #expect(await invocations.count == 2)
    #expect(replyThreadsValue(in: coordinator.selectedState.document) == "auto")
    #expect(coordinator.selectedState.problem?.message == "The selected OpenClaw model is unavailable.")
  }

  @Test("cancel clears pending mutation state before the panel reappears")
  func cancelClearsMutationState() async {
    let gate = InvocationGate()
    let coordinator = BotChatSettingsCoordinator(
      peer: .thread(id: 77),
      discoveryFetcher: { _ in discoveryResult() },
      settingsRequester: { _, _ in documentResponse(revision: "one") },
      itemInvoker: { _, _, _, _, _ in await gate.wait() }
    )
    await coordinator.warmUp()
    await waitUntil { coordinator.selectedState.phase == .loaded }

    coordinator.invoke(itemID: "following", value: .bool(true))
    #expect(coordinator.selectedState.isMutating)
    coordinator.cancel()

    #expect(coordinator.isMutating == false)
    #expect(coordinator.selectedState.isMutating == false)
    #expect(coordinator.selectedState.pendingItemID == nil)
  }

  @Test("drops an in-flight mutation when its bot becomes ineligible")
  func removesMutationForIneligibleBot() async {
    let discovery = MutableDiscovery(result: discoveryResult())
    let coordinator = BotChatSettingsCoordinator(
      peer: .thread(id: 77),
      discoveryFetcher: { _ in await discovery.result },
      settingsRequester: { _, _ in documentResponse(revision: "one") },
      itemInvoker: { _, _, _, _, _ in
        try await Task.sleep(for: .seconds(30))
        return documentResponse(revision: "never")
      }
    )
    await coordinator.warmUp()
    await waitUntil { coordinator.selectedState.phase == .loaded }

    coordinator.invoke(itemID: "following", value: .bool(true))
    #expect(coordinator.isMutating)

    await discovery.setResult(.init())
    coordinator.invalidateDiscovery()
    await waitUntil { coordinator.bots.isEmpty && !coordinator.isMutating }

    #expect(coordinator.selectedBotID == nil)
    #expect(coordinator.selectedState.pendingItemIDs.isEmpty)
  }

  @Test("preserves an unavailable explanation from the bot")
  func unavailableExplanation() async {
    let coordinator = BotChatSettingsCoordinator(
      peer: .user(id: 20),
      discoveryFetcher: { _ in discoveryResult() },
      settingsRequester: { _, _ in
        .with {
          $0.result = .problem(.with {
            $0.code = .unavailable
            $0.message = "Connect Hermes to load settings."
          })
        }
      },
      itemInvoker: { _, _, _, _, _ in documentResponse(revision: "two") }
    )

    await coordinator.warmUp()
    await waitUntil { coordinator.selectedState.phase == .unavailable }

    #expect(coordinator.selectedState.problem?.message == "Connect Hermes to load settings.")
  }

  @Test("reuses a fresh document and refreshes a stale one")
  func refreshFreshness() async {
    let requests = InvocationCounter()
    let coordinator = BotChatSettingsCoordinator(
      peer: .user(id: 20),
      discoveryFetcher: { _ in discoveryResult() },
      settingsRequester: { _, _ in
        await requests.increment()
        return documentResponse(revision: "one")
      },
      itemInvoker: { _, _, _, _, _ in documentResponse(revision: "two") }
    )

    await coordinator.warmUp()
    await waitUntil { coordinator.selectedState.phase == .loaded }
    coordinator.refreshSelectedIfStale(maxAge: 60)
    try? await Task.sleep(for: .milliseconds(5))
    #expect(await requests.count == 1)

    coordinator.refreshSelectedIfStale(maxAge: 0)
    await waitUntil { coordinator.selectedState.isRefreshing == false }
    #expect(await requests.count == 2)
  }

  @Test("keeps the last usable document when refresh is unreachable")
  func keepsDocumentOnUnreachableRefresh() async {
    let responses = SettingsResponseSequence(responses: [
      documentResponse(revision: "one", replyThreads: "auto"),
      .with {
        $0.result = .problem(.with {
          $0.code = .unreachable
          $0.message = "Bot unreachable"
        })
      },
    ])
    let coordinator = BotChatSettingsCoordinator(
      peer: .user(id: 20),
      discoveryFetcher: { _ in discoveryResult() },
      settingsRequester: { _, _ in await responses.next() },
      itemInvoker: { _, _, _, _, _ in documentResponse(revision: "two") }
    )

    await coordinator.warmUp()
    await waitUntil { coordinator.selectedState.phase == .loaded }
    coordinator.refreshSelectedIfStale(maxAge: 0)
    await waitUntil { coordinator.selectedState.problem == .unreachable }

    #expect(coordinator.selectedState.phase == .loaded)
    #expect(coordinator.selectedState.document?.revision == "one")
    #expect(replyThreadsValue(in: coordinator.selectedState.document) == "auto")
  }

  @Test("a cancelled request cannot clear a newer bot request")
  func cancelledRequestDoesNotClobberNewerRequest() async {
    let requests = SwitchingRequestGate()
    let coordinator = BotChatSettingsCoordinator(
      peer: .thread(id: 77),
      discoveryFetcher: { _ in discoveryResult() },
      settingsRequester: { _, botID in try await requests.request(botID: botID) },
      itemInvoker: { _, _, _, _, _ in documentResponse(revision: "mutation") }
    )

    await coordinator.warmUp()
    await waitUntil { coordinator.selectedState.document?.revision == "initial-20" }
    coordinator.selectBot(10)
    await waitUntil { coordinator.selectedState.document?.revision == "initial-10" }

    coordinator.selectBot(20)
    coordinator.refreshSelected()
    await waitUntilAsync { await requests.count(for: 20) == 2 }
    #expect(coordinator.selectedState.isRefreshing)

    coordinator.selectBot(10)
    coordinator.refreshSelected()
    await waitUntilAsync { await requests.count(for: 10) == 2 }
    await requests.failNext(botID: 20)
    try? await Task.sleep(for: .milliseconds(5))

    coordinator.refreshSelected()
    try? await Task.sleep(for: .milliseconds(5))
    #expect(await requests.count(for: 10) == 2)
    #expect(coordinator.selectedState.isRefreshing)
    #expect(coordinator.selectedState.problem == nil)

    await requests.resolveNext(botID: 10, with: documentResponse(revision: "fresh-10"))
    await waitUntil { coordinator.selectedState.document?.revision == "fresh-10" }
    #expect(coordinator.selectedState.isRefreshing == false)
  }
}

private actor InvocationCounter {
  private(set) var count = 0
  func increment() { count += 1 }
}

private actor TransientMutationSequence {
  enum Failure: Error { case disconnected }

  private(set) var count = 0

  func invoke() throws -> InlineProtocol.BotChatSettingsResponse {
    count += 1
    if count == 1 { throw Failure.disconnected }
    return documentResponse(revision: "two", replyThreads: "on")
  }
}

private actor FailedMutationSequence {
  struct Failure: LocalizedError {
    var errorDescription: String? { "The selected OpenClaw model is unavailable." }
  }

  private(set) var count = 0

  func invoke() throws -> InlineProtocol.BotChatSettingsResponse {
    count += 1
    throw Failure()
  }
}

private actor InvocationGate {
  func wait() async -> InlineProtocol.BotChatSettingsResponse {
    try? await Task.sleep(for: .seconds(30))
    return documentResponse(revision: "never")
  }
}

private actor MutationGate {
  struct Call: Equatable, Sendable {
    let itemID: String
    let value: BotChatSettingsMutationValue?
    let revision: String
  }

  private(set) var calls: [Call] = []
  private var continuations: [CheckedContinuation<InlineProtocol.BotChatSettingsResponse, Never>] = []

  var count: Int { calls.count }

  func call(at index: Int) -> Call? {
    calls.indices.contains(index) ? calls[index] : nil
  }

  func invoke(
    itemID: String,
    value: BotChatSettingsMutationValue?,
    revision: String
  ) async -> InlineProtocol.BotChatSettingsResponse {
    calls.append(.init(itemID: itemID, value: value, revision: revision))
    return await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func resolveNext(with response: InlineProtocol.BotChatSettingsResponse) {
    guard !continuations.isEmpty else { return }
    continuations.removeFirst().resume(returning: response)
  }
}

private actor DiscoverySequence {
  private(set) var count = 0

  func next() -> InlineProtocol.GetPeerBotsResult {
    count += 1
    return count == 1 ? .init() : discoveryResult()
  }
}

private actor MutableDiscovery {
  private(set) var result: InlineProtocol.GetPeerBotsResult

  init(result: InlineProtocol.GetPeerBotsResult) {
    self.result = result
  }

  func setResult(_ result: InlineProtocol.GetPeerBotsResult) {
    self.result = result
  }
}

private actor SettingsResponseSequence {
  private var responses: [InlineProtocol.BotChatSettingsResponse]

  init(responses: [InlineProtocol.BotChatSettingsResponse]) {
    self.responses = responses
  }

  func next() -> InlineProtocol.BotChatSettingsResponse {
    responses.isEmpty ? .init() : responses.removeFirst()
  }
}

private actor SwitchingRequestGate {
  enum Failure: Error { case staleRequestFailed }

  private var counts: [Int64: Int] = [:]
  private var continuations: [Int64: [CheckedContinuation<InlineProtocol.BotChatSettingsResponse, any Error>]] = [:]

  func count(for botID: Int64) -> Int {
    counts[botID, default: 0]
  }

  func request(botID: Int64) async throws -> InlineProtocol.BotChatSettingsResponse {
    counts[botID, default: 0] += 1
    if counts[botID] == 1 {
      return documentResponse(revision: "initial-\(botID)")
    }
    return try await withCheckedThrowingContinuation { continuation in
      continuations[botID, default: []].append(continuation)
    }
  }

  func failNext(botID: Int64) {
    guard continuations[botID]?.isEmpty == false else { return }
    continuations[botID]?.removeFirst().resume(throwing: Failure.staleRequestFailed)
  }

  func resolveNext(botID: Int64, with response: InlineProtocol.BotChatSettingsResponse) {
    guard continuations[botID]?.isEmpty == false else { return }
    continuations[botID]?.removeFirst().resume(returning: response)
  }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
  for _ in 0 ..< 200 {
    if condition() { return }
    await Task.yield()
    try? await Task.sleep(for: .milliseconds(1))
  }
}

@MainActor
private func waitUntilAsync(_ condition: () async -> Bool) async {
  for _ in 0 ..< 200 {
    if await condition() { return }
    await Task.yield()
    try? await Task.sleep(for: .milliseconds(1))
  }
}

private func discoveryResult() -> InlineProtocol.GetPeerBotsResult {
  .with {
    $0.bots = [peerBot(id: 10, name: "Hermes"), peerBot(id: 20, name: "OpenClaw")]
    $0.suggestedBotUserID = 20
  }
}

private func peerBot(id: Int64, name: String) -> InlineProtocol.PeerBot {
  .with {
    $0.bot = .with {
      $0.id = id
      $0.firstName = name
      $0.bot = true
    }
    $0.capabilities = [.with {
      $0.kind = .chatSettings
      $0.version = 1
    }]
  }
}

private func documentResponse(
  revision: String,
  following: Bool = false,
  replyThreads: String = "auto"
) -> InlineProtocol.BotChatSettingsResponse {
  .with {
    $0.result = .document(.with {
      $0.version = 1
      $0.revision = revision
      $0.sections = [.with {
        $0.id = "attention"
        $0.items = [
          .with {
            $0.id = "following"
            $0.label = "Following"
            $0.control = .toggle(.with { $0.value = following })
          },
          .with {
            $0.id = "reply-threads"
            $0.label = "Reply in threads"
            $0.control = .select(.with {
              $0.value = replyThreads
              $0.options = [
                selectOption(value: "auto", label: "Auto"),
                selectOption(value: "on", label: "On"),
                selectOption(value: "off", label: "Off"),
              ]
            })
          },
        ]
      }]
    })
  }
}

private func staleResponse(
  revision: String,
  replyThreads: String
) -> InlineProtocol.BotChatSettingsResponse {
  .with {
    $0.result = .problem(.with {
      $0.code = .stale
      $0.message = "Settings changed"
      if case let .document(document)? = documentResponse(
        revision: revision,
        replyThreads: replyThreads
      ).result {
        $0.currentDocument = document
      }
    })
  }
}

private func selectOption(value: String, label: String) -> InlineProtocol.BotChatSettingsSelectOption {
  .with {
    $0.value = value
    $0.label = label
  }
}

private func replyThreadsValue(in document: BotChatSettingsModel.Document?) -> String? {
  guard let item = document?.sections.flatMap(\.items).first(where: { $0.id == "reply-threads" }),
        case let .select(value, _) = item.control
  else { return nil }
  return value
}

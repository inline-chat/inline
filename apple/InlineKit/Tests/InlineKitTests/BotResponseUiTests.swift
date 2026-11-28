import Combine
import Foundation
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Bot response answers")
struct BotResponseUiTests {
  private func openURL(_ url: String, sensitive: Bool = false, host: String? = nil, hint: String? = nil) -> BotResponseOpenURL? {
    let ui = InlineProtocol.MessageActionResponseUi.with {
      $0.openURL = .with {
        $0.url = url
        $0.sensitive = sensitive
        if let host { $0.hostLabel = host }
        if let hint { $0.unreachableText = hint }
      }
    }
    guard case let .openURL(open)? = BotResponseUi(ui) else { return nil }
    return open
  }

  @Test("parses toast, alert and URL answers and rejects unsafe URLs")
  func parsing() {
    #expect(BotResponseUi(.with { $0.toast = .with { $0.text = " Saved " } }) == .toast("Saved"))
    #expect(BotResponseUi(.with { $0.toast = .with { $0.text = "  " } }) == nil)
    #expect(openURL("https://example.com/")?.isWeb == true)
    #expect(openURL("javascript:alert(1)") == nil)
    #expect(openURL("file:///etc/passwd") == nil)
  }

  @Test("recognizes loopback hosts")
  func loopback() {
    #expect(openURL("http://127.0.0.1:18789/")?.isLoopback == true)
    #expect(openURL("http://localhost:9119/")?.isLoopback == true)
    #expect(openURL("http://[::1]:9119/")?.isLoopback == true)
    #expect(openURL("https://mo-mbp.tail1234.ts.net/")?.isLoopback == false)
  }

  @Test("opens a fresh reachable URL")
  func opensFresh() async throws {
    let open = try #require(openURL("http://127.0.0.1:18789/#bootstrapToken=abc", sensitive: true))
    let decision = await BotResponseURLResolver.decide(open, pressedAt: Date(), probe: { _ in true })
    #expect(decision == .open(open.url))
  }

  @Test("never opens an answer that arrives after the window")
  func expires() async throws {
    let open = try #require(openURL("https://example.com/"))
    let pressedAt = Date().addingTimeInterval(-(BotResponseOpenURL.openWindow + 1))
    #expect(await BotResponseURLResolver.decide(open, pressedAt: pressedAt, probe: { _ in true }) == .expired)
  }

  @Test("explains an unreachable loopback URL with the bot's advice")
  func unreachable() async throws {
    let open = try #require(openURL(
      "http://127.0.0.1:18789/",
      host: "Mo's MacBook Pro",
      hint: "Turn on Tailscale Serve for OpenClaw."
    ))
    let decision = await BotResponseURLResolver.decide(open, pressedAt: Date(), probe: { _ in false })
    #expect(decision == .unreachable(.init(
      title: "This only opens on Mo's MacBook Pro",
      text: "Turn on Tailscale Serve for OpenClaw."
    )))
  }

  @Test("only probes loopback URLs")
  func probesLoopbackOnly() async throws {
    let open = try #require(openURL("https://mo-mbp.tail1234.ts.net/"))
    let decision = await BotResponseURLResolver.decide(open, pressedAt: Date(), probe: { _ in false })
    #expect(decision == .open(open.url))
  }

  @Test("asks before an app link and keeps a credential off screen")
  func confirmsAppLinks() async throws {
    let open = try #require(openURL("codex://threads/1?token=secret", sensitive: true))
    guard case let .confirm(url, confirmation) = await BotResponseURLResolver.decide(open, pressedAt: Date()) else {
      Issue.record("expected a confirmation")
      return
    }
    #expect(url == open.url)
    #expect(confirmation.text == "codex://threads")
  }

  @Test("message button answers carry the URL and the press time")
  @MainActor
  func messageActionAnswer() throws {
    let state = MessageActionInteractionState()
    let key = MessageActionInteractionState.LoadingKey(peerId: .thread(id: 1), messageId: 2, rev: 0, actionId: "open")
    var received: MessageActionInteractionState.AnswerEvent?
    let cancellable = state.answeredPublisher.sink { received = $0 }
    defer { cancellable.cancel() }

    let before = Date()
    #expect(state.begin(key: key))
    state.attachInteractionId(9, for: key)
    let open = try #require(openURL("https://example.com/"))
    state.finish(interactionId: 9, openURL: open)

    #expect(received?.openURL == open)
    #expect((received?.pressedAt ?? .distantPast) >= before)
  }
}

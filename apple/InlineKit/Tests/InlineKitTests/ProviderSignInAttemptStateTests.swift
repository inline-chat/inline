import Foundation
import Testing

@testable import InlineKit

@Suite("Provider sign-in attempt ownership")
struct ProviderSignInAttemptStateTests {
  @Test("a stale callback cannot consume the newer attempt")
  func staleCallbackCannotConsumeNewAttempt() {
    var state = ProviderSignInAttemptState()
    let first = state.begin(
      provider: .google,
      codeVerifier: "first-verifier",
      codeChallenge: "first-challenge"
    )
    let second = state.begin(
      provider: .apple,
      codeVerifier: "second-verifier",
      codeChallenge: "second-challenge"
    )

    #expect(state.take(codeChallenge: first.codeChallenge) == nil)
    #expect(state.pending == second)
    #expect(state.take(codeChallenge: second.codeChallenge) == second)
    #expect(state.pending == nil)
  }

  @Test("stale start failures and cancellations leave the current attempt intact")
  func staleFailureDoesNotClearCurrentAttempt() {
    var state = ProviderSignInAttemptState()
    let first = state.begin(
      provider: .google,
      codeVerifier: "first-verifier",
      codeChallenge: "first-challenge"
    )
    let second = state.begin(
      provider: .google,
      codeVerifier: "second-verifier",
      codeChallenge: "second-challenge"
    )

    state.cancel(generation: first.generation)
    state.cancel(codeChallenge: first.codeChallenge)
    #expect(state.pending == second)
  }

  @Test("matching terminal callbacks consume their verifier exactly once")
  func matchingCallbackConsumesOnce() {
    var state = ProviderSignInAttemptState()
    let attempt = state.begin(
      provider: .apple,
      codeVerifier: "verifier",
      codeChallenge: "challenge"
    )

    #expect(state.take(codeChallenge: attempt.codeChallenge) == attempt)
    #expect(state.take(codeChallenge: attempt.codeChallenge) == nil)
  }

  @Test("browser sign-in invalidates an in-flight native Apple preparation")
  func browserAttemptWinsOverLateNativePreparation() {
    let appleGeneration = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let googleGeneration = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    var state = ProviderSignInAttemptState()

    state.beginNativePreparation(generation: appleGeneration)
    let googleAttempt = state.begin(
      provider: .google,
      codeVerifier: "google-verifier",
      codeChallenge: "google-challenge",
      generation: googleGeneration
    )
    let lateAppleAttempt = state.finishNativePreparation(
      generation: appleGeneration,
      codeVerifier: "apple-verifier",
      codeChallenge: "apple-challenge",
      state: "apple-state"
    )

    #expect(lateAppleAttempt == nil)
    #expect(state.pending == googleAttempt)
  }

  @Test("native Apple preparation immediately invalidates an existing browser attempt")
  func nativePreparationWinsOverExistingBrowserAttempt() {
    let appleGeneration = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    var state = ProviderSignInAttemptState()
    _ = state.begin(
      provider: .google,
      codeVerifier: "google-verifier",
      codeChallenge: "google-challenge"
    )

    state.beginNativePreparation(generation: appleGeneration)
    let appleAttempt = state.finishNativePreparation(
      generation: appleGeneration,
      codeVerifier: "apple-verifier",
      codeChallenge: "apple-challenge",
      state: "apple-state"
    )

    #expect(appleAttempt?.provider == .apple)
    #expect(appleAttempt?.nativeAppleState == "apple-state")
    #expect(state.pending == appleAttempt)
  }
}

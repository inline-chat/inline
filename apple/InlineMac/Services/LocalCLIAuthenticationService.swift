import InlineCLIInstaller

enum LocalCLIAuthenticationService {
  @MainActor
  static func authenticate(
    _ installation: CLIInstallation,
    dependencies: AppDependencies
  ) async throws -> CLIAuthBootstrapResult {
    guard let expectedUserID = dependencies.auth.getCurrentUserId(), expectedUserID > 0 else {
      throw CLIAuthBootstrapError.unexpectedUser
    }
    let bootstrapper = CLIAuthBootstrapper()
    var deliveredSessionID: Int64?
    do {
      let result = try await bootstrapper.authenticate(
        installation: installation,
        expectedUserID: expectedUserID
      ) { request in
        guard let endpoint = LocalCLIAuthBroker.Endpoint(url: request.callbackURL) else {
          throw CLIAuthBootstrapError.invalidHandshake
        }
        do {
          let client = try await LocalCLIAuthBroker.probe(endpoint)
          deliveredSessionID = try await LocalCLIAuthBroker.createAndDeliverSession(
            endpoint,
            client: client,
            realtime: dependencies.realtimeV2
          )
        } catch {
          await LocalCLIAuthBroker.cancel(
            endpoint,
            detail: "Inline for Mac could not complete the request."
          )
          throw error
        }
      }
      guard result.userID == expectedUserID else {
        throw CLIAuthBootstrapError.unexpectedUser
      }
      deliveredSessionID = nil
      return result
    } catch {
      if let deliveredSessionID {
        _ = try? await dependencies.realtimeV2.revokeSession(deliveredSessionID)
      }
      throw error
    }
  }
}

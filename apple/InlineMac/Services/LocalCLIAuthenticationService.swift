import InlineCLIInstaller

enum LocalCLIAuthenticationService {
  @MainActor
  static func authenticate(
    _ installation: CLIInstallation,
    dependencies: AppDependencies
  ) async throws -> CLIAuthBootstrapResult {
    let bootstrapper = CLIAuthBootstrapper()
    var deliveredSessionID: Int64?
    do {
      let result = try await bootstrapper.authenticate(installation: installation) { request in
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

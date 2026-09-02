// Kept independent of authentication services so presentation tools can share the same route type.
public enum ProviderSignInProvider: String, Hashable, Sendable {
  case google
  case apple
}

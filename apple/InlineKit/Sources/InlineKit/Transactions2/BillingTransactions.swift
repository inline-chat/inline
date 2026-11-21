import Foundation
import InlineProtocol
import Logger
import RealtimeV2

/// The viewer's plan, the plans of spaces they administer, and what they can buy.
/// Nothing is cached: billing screens read it when they appear.
public struct GetBillingTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/GetBilling")

  public var method: InlineProtocol.Method = .getBilling
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {}

  public init() {
    context = Context()
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getBilling(.init())
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func optimistic() async {}

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .getBilling = result else { throw TransactionExecutionError.invalid }
  }

  public func failed(error: TransactionError2) async {
    log.error("Failed to get billing", error: error)
  }

  public func cancelled() async {}
}

/// Starts a Stripe checkout for a plan code and returns its URL.
public struct CreateBillingCheckoutTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/CreateBillingCheckout")

  public var method: InlineProtocol.Method = .createBillingCheckout
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    public var plan: String
    public var spaceID: Int64?
  }

  public init(plan: String, spaceID: Int64?) {
    context = Context(plan: plan, spaceID: spaceID)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .createBillingCheckout(.with {
      $0.plan = context.plan
      if let spaceID = context.spaceID { $0.spaceID = spaceID }
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func optimistic() async {}

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .createBillingCheckout = result else { throw TransactionExecutionError.invalid }
  }

  public func failed(error: TransactionError2) async {
    log.error("Failed to start checkout", error: error)
  }

  public func cancelled() async {}
}

/// Opens Stripe's page for cancelling, changing the card and viewing invoices.
public struct CreateBillingPortalTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/CreateBillingPortal")

  public var method: InlineProtocol.Method = .createBillingPortal
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    public var spaceID: Int64?
  }

  public init(spaceID: Int64?) {
    context = Context(spaceID: spaceID)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .createBillingPortal(.with {
      if let spaceID = context.spaceID { $0.spaceID = spaceID }
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func optimistic() async {}

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .createBillingPortal = result else { throw TransactionExecutionError.invalid }
  }

  public func failed(error: TransactionError2) async {
    log.error("Failed to open billing management", error: error)
  }

  public func cancelled() async {}
}

public extension Transaction2 where Self == GetBillingTransaction {
  static func getBilling() -> GetBillingTransaction { GetBillingTransaction() }
}

public extension Transaction2 where Self == CreateBillingCheckoutTransaction {
  static func createBillingCheckout(plan: String, spaceID: Int64? = nil) -> CreateBillingCheckoutTransaction {
    CreateBillingCheckoutTransaction(plan: plan, spaceID: spaceID)
  }
}

public extension Transaction2 where Self == CreateBillingPortalTransaction {
  static func createBillingPortal(spaceID: Int64? = nil) -> CreateBillingPortalTransaction {
    CreateBillingPortalTransaction(spaceID: spaceID)
  }
}

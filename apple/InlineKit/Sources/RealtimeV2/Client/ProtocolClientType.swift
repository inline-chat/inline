import Foundation
import InlineProtocol

protocol ProtocolClientType: AnyObject, Sendable {
  @discardableResult
  func callRpc(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout: Duration?
  ) async throws -> InlineProtocol.RpcResult.OneOf_Result?
}

import InlineProtocol

public enum RealtimeAPIError: Error {
  case rpcError(errorCode: RpcError.Code, message: String?, code: Int)
  case unknown(Error)
  case notAuthorized
  case stopped
  case notConnected
}

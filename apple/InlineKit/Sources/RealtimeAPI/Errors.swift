import InlineProtocol

enum TransportError: Error {
  case invalidURL
  case invalidResponse
  case invalidData
  case connectionError(Error)
  case connectionTimeout
  case unknown
  case notConnected
}

public enum RealtimeAPIError: Error {
  case rpcError(errorCode: RpcError.Code, message: String?)
  case unknown(Error)
  case notAuthorized
  case stopped
}

public extension AsyncStream {
  static func create(
    _ elementType: Element.Type = Element.self,
    bufferingPolicy limit: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded
  ) -> (AsyncStream<Element>, AsyncStream<Element>.Continuation) {
    var continuation: AsyncStream<Element>.Continuation!
    let stream = AsyncStream(bufferingPolicy: limit) { continuation = $0 }
    return (stream, continuation)
  }
}

public extension Task {
  func store(in set: inout Set<Self>) {
    set.insert(self)
  }
}

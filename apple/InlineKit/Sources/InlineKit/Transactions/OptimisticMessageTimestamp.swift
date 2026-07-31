import Foundation

/// Produces the whole-second timestamp used by the server for message ordering.
public func optimisticMessageTimestamp(for date: Date = Date()) -> Int64 {
  Int64(date.timeIntervalSince1970)
}

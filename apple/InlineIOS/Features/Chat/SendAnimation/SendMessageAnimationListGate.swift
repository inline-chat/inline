import UIKit

/// A message list that hosts the send animation: the
/// composer prepares a flight only while the list says it would show the new message.
@MainActor
protocol SendMessageAnimationListGate: AnyObject {
  var acceptsSendAnimation: Bool { get }
}

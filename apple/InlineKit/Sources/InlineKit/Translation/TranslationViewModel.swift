import Combine
import InlineProtocol
import Logger

class TranslationViewModel {
  private let db = AppDatabase.shared
  private let realtime = Realtime.shared
  private let log = Log.scoped("TranslationViewModel")

  private var cancellables = Set<AnyCancellable>()

  private var peerId: Peer

  init(peerId: Peer) {
    self.peerId = peerId
  }

  func messagesDisplayed(messages: [FullMessage]) {
    log.debug("messages displayed peer \(peerId) - count \(messages.count)")

    //  check if translation is enabled for the peer
    //  if it is, then check if the message has a translation for the current language
    //  if it does, then add the translation to the message
    //  if it doesn't, then add the message to the list
    //  return the list of messages
  }
}

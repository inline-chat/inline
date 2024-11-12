import InlineKit
import SwiftUI

struct MessageView: View {
  var message: Message
//  var sender: User

  var body: some View {
    Text(message.text ?? "")
  }
}

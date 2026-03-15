import Foundation

protocol SlashCommandManagerDelegate: AnyObject {
  func slashCommandManager(_ manager: SlashCommandManager, didInsertCommand text: String, for range: NSRange)
  func slashCommandManagerDidDismiss(_ manager: SlashCommandManager)
}

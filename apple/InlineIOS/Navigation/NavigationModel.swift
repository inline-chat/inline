import Foundation
import Playgrounds
import SwiftUI

@Observable
@MainActor
public final class NavigationModel<Tab: TabType, Destination: DestinationType, Sheet: SheetType> {
  private var paths: [Tab: [Destination]] = [:]

  public var selectedTab: Tab
  public var presentedSheet: Sheet?

  public init(initialTab: Tab) {
    self.selectedTab = initialTab
  }

  public subscript(tab: Tab) -> [Destination] {
    get { paths[tab] ?? [] }
    set { paths[tab] = newValue }
  }

  public var selectedTabPath: [Destination] {
    paths[selectedTab] ?? []
  }

  public func popToRoot(for tab: Tab? = nil) {
    paths[tab ?? selectedTab] = []
  }

  public func pop(for tab: Tab? = nil) {
    let targetTab = tab ?? selectedTab
    if paths[targetTab]?.isEmpty == false {
      paths[targetTab]?.removeLast()
    }
  }

  public func push(_ destination: Destination, for tab: Tab? = nil) {
    let targetTab = tab ?? selectedTab
    if paths[targetTab] == nil {
      paths[targetTab] = [destination]
    } else {
      paths[targetTab]?.append(destination)
    }
  }

  public func presentSheet(_ sheet: Sheet) {
    presentedSheet = sheet
  }

  public func dismissSheet() {
    presentedSheet = nil
  }
}

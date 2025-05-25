import Foundation
import SwiftUI

class TabsManager: ObservableObject {
  static let shared = TabsManager()

  enum Tab: Int, CaseIterable {
    case archived = 0
    case chats = 1
    case spaces = 2
  }

  private let defaultTab: Tab = .chats
  private let userDefaultsKey = "selectedTab"

  @Published private(set) var selectedTab: Tab
  @Published var activeSpaceId: Int64? = UserDefaults.standard.object(forKey: "activeSpaceId") as? Int64

  public init() {
    if let savedValue = UserDefaults.standard.object(forKey: userDefaultsKey) as? Int,
       let tab = Tab(rawValue: savedValue)
    {
      selectedTab = tab
    } else {
      selectedTab = defaultTab
    }

    if let savedValue = UserDefaults.standard.object(forKey: "activeSpaceId") as? Int64 {
      activeSpaceId = savedValue
    }
  }

  func setActiveSpaceId(_ id: Int64?) {
    activeSpaceId = id
    saveActiveSpaceId()
  }

  func clearActiveSpaceId() {
    print("Clearning active spaceId")
    activeSpaceId = nil
    saveActiveSpaceId()
  }

  func getActiveSpaceId() -> Int64? {
    activeSpaceId
  }

  private func saveActiveSpaceId() {
    UserDefaults.standard.set(activeSpaceId, forKey: "activeSpaceId")
  }

  func setSelectedTab(_ tab: Tab) {
    selectedTab = tab
    saveSelectedTab()
  }

  func getSelectedTab() -> Tab {
    selectedTab
  }

  private func saveSelectedTab() {
    UserDefaults.standard.set(selectedTab.rawValue, forKey: userDefaultsKey)
  }

  func reset() {
    selectedTab = defaultTab
    saveSelectedTab()
  }
}

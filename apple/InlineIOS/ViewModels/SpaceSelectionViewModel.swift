import InlineKit
import SwiftUI

@MainActor
final class SpaceSelectionViewModel: ObservableObject {
  @Published var selectedSpaceId: Int64? {
    didSet { persistSelection() }
  }

  private let selectionKey = "spaceSelection.selectedSpaceId"

  init() {
    if let stored = UserDefaults.standard.object(forKey: selectionKey) as? NSNumber {
      selectedSpaceId = stored.int64Value
    } else {
      selectedSpaceId = nil
    }
  }

  func selectedSpace(in spaces: [HomeSpaceItem]) -> Space? {
    guard let selectedSpaceId else { return nil }
    return spaces.first { $0.space.id == selectedSpaceId }?.space
  }

  func selectSpace(_ id: Int64?, availableSpaces: [HomeSpaceItem]) {
    guard let id else {
      selectedSpaceId = nil
      return
    }

    guard availableSpaces.contains(where: { $0.space.id == id }) else {
      selectedSpaceId = nil
      return
    }

    selectedSpaceId = id
  }

  func pruneSelectionIfNeeded(spaces: [HomeSpaceItem]) {
    if let id = selectedSpaceId, !spaces.contains(where: { $0.space.id == id }) {
      selectedSpaceId = nil
    }
  }

  private func persistSelection() {
    if let selectedSpaceId {
      UserDefaults.standard.set(NSNumber(value: selectedSpaceId), forKey: selectionKey)
    } else {
      UserDefaults.standard.removeObject(forKey: selectionKey)
    }
  }
}

enum AttachmentPickerLibraryActionTarget {
  case openLibrary
  case manageLimitedAccess
}

private enum AttachmentPickerSelectedMediaLabel {
  case photo
  case video
  case item

  init(selectedItems: [AttachmentPickerModel.RecentItem]) {
    let mediaTypes = Set(selectedItems.map(\.mediaType))
    if mediaTypes.count > 1 {
      self = .item
      return
    }

    switch mediaTypes.first {
    case .video:
      self = .video
    case .image:
      self = .photo
    case .none:
      self = .item
    }
  }

  func text(for count: Int) -> String {
    let singularText: String
    let pluralText: String
    switch self {
    case .photo:
      singularText = "photo"
      pluralText = "photos"
    case .video:
      singularText = "video"
      pluralText = "videos"
    case .item:
      singularText = "item"
      pluralText = "items"
    }

    if count == 1 {
      return "Add 1 \(singularText)"
    }
    return "Add \(count) \(pluralText)"
  }
}

func attachmentPickerSendSelectedButtonTitle(for selectedItems: [AttachmentPickerModel.RecentItem]) -> String {
  let count = selectedItems.count
  let label = AttachmentPickerSelectedMediaLabel(selectedItems: selectedItems)
  return label.text(for: count)
}

func resolveAttachmentPickerLibraryActionTarget(
  showsLimitedAccessNotice: Bool
) -> AttachmentPickerLibraryActionTarget {
  if showsLimitedAccessNotice {
    return .manageLimitedAccess
  }

  return .openLibrary
}

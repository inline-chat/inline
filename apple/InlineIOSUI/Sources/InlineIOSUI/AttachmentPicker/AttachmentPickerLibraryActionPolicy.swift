enum AttachmentPickerLibraryActionTarget {
  case openLibrary
  case manageLimitedAccess
}

func resolveAttachmentPickerLibraryActionTarget(
  showsLimitedAccessNotice: Bool
) -> AttachmentPickerLibraryActionTarget {
  if showsLimitedAccessNotice {
    return .manageLimitedAccess
  }

  return .openLibrary
}

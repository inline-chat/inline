enum AttachmentPickerLibraryActionTarget {
  case openLibrary
  case manageLimitedAccess
}

func resolveAttachmentPickerLibraryActionTarget(
  showsLimitedAccessNotice: Bool
) -> AttachmentPickerLibraryActionTarget {
  _ = showsLimitedAccessNotice
  return .openLibrary
}

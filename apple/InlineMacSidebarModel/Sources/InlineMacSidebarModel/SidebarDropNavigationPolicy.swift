public enum SidebarDropNavigationPresentation: Equatable, Sendable {
  case primary
  case replySidePane
}

public enum SidebarDropNavigationPolicy {
  public static func presentation(
    presentationParentExists: Bool,
    prefersReplySidePane: Bool
  ) -> SidebarDropNavigationPresentation {
    presentationParentExists && prefersReplySidePane ? .replySidePane : .primary
  }
}

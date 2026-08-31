import SwiftUI

private enum GalleryAppearance: String, CaseIterable, Identifiable {
  case system = "System", light = "Light", dark = "Dark"
  var id: String { rawValue }
  var colorScheme: ColorScheme? {
    switch self {
      case .system: nil
      case .light: .light
      case .dark: .dark
    }
  }
}

private enum GalleryPhoneSize: String, CaseIterable, Identifiable {
  case compact = "Compact", standard = "Standard", large = "Large"
  var id: String { rawValue }
  var size: CGSize {
    switch self {
      case .compact: CGSize(width: 375, height: 667)
      case .standard: CGSize(width: 393, height: 852)
      case .large: CGSize(width: 430, height: 932)
    }
  }
}

struct OnboardingGalleryView: View {
  @Environment(\.colorScheme) private var systemColorScheme
  @ObservedObject private var session: OnboardingGallerySession
  @ObservedObject private var navigation: OnboardingNavigation
  @ObservedObject private var provider: OnboardingGalleryProviderState
  @State private var appearance: GalleryAppearance = .system
  @State private var phoneSize: GalleryPhoneSize = .standard
  @State private var search = ""

  init(session: OnboardingGallerySession) {
    self.session = session
    navigation = session.navigation
    provider = session.provider
  }

  var body: some View {
    HStack(spacing: 0) {
      sidebar
        .frame(width: 270)
      Divider()
      VStack(spacing: 0) {
        controls
        Divider()
        canvas
        sourceCaption
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(uiColor: .secondarySystemBackground))
    }
    .onChange(of: navigation.path) { _, path in
      if let page = OnboardingGalleryPage(route: path.last ?? .welcome) {
        session.selectedPage = page
        if !page.isProviderProgress {
          provider.reset()
        }
      }
    }
    .alert("Preview complete", isPresented: $session.didFinish) {
      Button("Back to Welcome") { session.show(.welcome) }
      Button("Stay Here", role: .cancel) {}
    } message: {
      Text("You reached the end of onboarding. No account was created and nothing was sent or saved.")
    }
    .alert("Browser sign-in is disabled", isPresented: $provider.showBrowserNotice) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("This gallery uses the real progress view with local sample state. No browser or authentication session is opened.")
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text("iOS onboarding")
          .font(.title2.bold())
        Text("\(OnboardingGalleryPage.allCases.count) pages · shared iOS views")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        TextField("Find a page", text: $search)
          .textFieldStyle(.roundedBorder)
          .autocorrectionDisabled()
          .accessibilityIdentifier("gallery.search")
          .padding(.top, 12)
      }
      .padding(20)

      List(selection: Binding<OnboardingGalleryPage?>(
        get: { session.selectedPage },
        set: { if let page = $0 { session.show(page) } }
      )) {
        ForEach(OnboardingGalleryPage.Section.allCases) { section in
          let pages = OnboardingGalleryPage.allCases.filter {
            $0.section == section && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
          }
          if !pages.isEmpty {
            Section(section.rawValue) {
              ForEach(pages) { page in
                Label(page.title, systemImage: page.symbol)
                  .font(.body)
                  .tag(page)
                  .accessibilityIdentifier("gallery.page.\(page.rawValue)")
              }
            }
          }
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)

      Label("Local preview only", systemImage: "lock.shield")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(20)
    }
    .background(Color(uiColor: .systemBackground))
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(session.selectedPage.title)
            .font(.title3.weight(.semibold))
          Text("Interactive production view · demo actions")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Button {
          session.show(session.selectedPage)
        } label: {
          Label("Reset", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.bordered)
        .keyboardShortcut("r", modifiers: .command)
        .accessibilityIdentifier("gallery.reset")
      }

      HStack(spacing: 16) {
        Picker("Appearance", selection: $appearance) {
          ForEach(GalleryAppearance.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 290)
        .accessibilityIdentifier("gallery.appearance")

        Picker("Canvas", selection: $phoneSize) {
          ForEach(GalleryPhoneSize.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("gallery.canvasSize")

        if session.selectedPage.isProviderProgress {
          Menu("State") {
            Button(session.selectedPage == .nativeApple ? "Progress" : "Waiting for browser") { provider.reset() }
            if session.selectedPage != .nativeApple {
              Button("Finishing sign-in") {
                provider.clearError()
                provider.isRedeeming = true
              }
            }
            Button("Error") {
              provider.isRedeeming = false
              provider.errorMessage = "Sign-in couldn’t finish. Please try again."
            }
          }
          .accessibilityIdentifier("gallery.providerState")
        }
      }
    }
    .padding(20)
    .background(Color(uiColor: .systemBackground))
  }

  private var canvas: some View {
    GeometryReader { geometry in
      let size = phoneSize.size
      let scale = max(0.1, min(1, (geometry.size.width - 48) / size.width, (geometry.size.height - 48) / size.height))

      OnboardingGalleryPreview(
        navigation: navigation,
        session: session,
        provider: provider,
        colorScheme: appearance.colorScheme ?? systemColorScheme
      )
        .frame(width: size.width, height: size.height)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay {
          RoundedRectangle(cornerRadius: 28)
            .strokeBorder(.gray.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
        .id(session.previewID)
        .scaleEffect(scale)
        .frame(width: size.width * scale, height: size.height * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("gallery.preview")
    }
  }

  private var sourceCaption: some View {
    VStack(spacing: 6) {
      Text(session.selectedPage.hint)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Text("\(session.selectedPage.viewName) · InlineIOS/Auth/\(session.selectedPage.sourceFile)")
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
      Text("\(Int(phoneSize.size.width)) × \(Int(phoneSize.size.height)) pt · UIKit on Mac Catalyst")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 24)
    .padding(.bottom, 18)
    .frame(maxWidth: .infinity)
  }
}

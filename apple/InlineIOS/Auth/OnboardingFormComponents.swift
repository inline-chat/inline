import InlineUI
import SwiftUI

enum OnboardingFormMetrics {
  static let horizontalPadding: CGFloat = 20
  static let controlHeight: CGFloat = 52
}

struct OnboardingFormPage<Content: View, Actions: View>: View {
  var focus: FocusState<Bool>.Binding? = nil
  var autofocus = true
  @ViewBuilder var content: Content
  @ViewBuilder var actions: Actions

  var body: some View {
    ScrollView {
      VStack(spacing: 24) {
        content
      }
      .padding(.horizontal, OnboardingFormMetrics.horizontalPadding)
      .padding(.vertical, 20)
      .frame(maxWidth: .infinity)
    }
    .defaultScrollAnchor(.center, for: .alignment)
    .scrollIndicators(.hidden)
    .scrollBounceBehavior(.basedOnSize)
    .scrollDismissesKeyboard(.interactively)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 12) {
        actions
      }
      .padding(.horizontal, OnboardingFormMetrics.horizontalPadding)
      .padding(.top, 12)
      .padding(.bottom, OnboardingUtils.shared.buttonBottomPadding)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      focus?.wrappedValue = false
    }
    .onAppear {
      focus?.wrappedValue = autofocus
    }
    .onDisappear {
      // Do not retain focus while this form is off screen.
      focus?.wrappedValue = false
    }
  }
}

struct OnboardingFormHeader: View {
  let title: Text
  let systemImage: String

  var body: some View {
    VStack(spacing: 14) {
      icon
        .accessibilityHidden(true)

      title
        .font(.onboardingIOSTitle.bold())
        .foregroundStyle(.primary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
    }
  }

  @ViewBuilder
  private var icon: some View {
    let image = Image(systemName: systemImage)
      .scaledFont(size: 38, weight: .regular)
      .foregroundStyle(.primary)
      .scaledFrame(width: 66, height: 66)

    if #available(iOS 26.0, *) {
      image
        .contentShape(.circle)
        .glassEffect(.regular.interactive(), in: .circle)
    } else {
      image
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.8), in: Circle())
    }
  }
}

private struct OnboardingFormFieldModifier: ViewModifier {
  @ScaledMetric(relativeTo: .body) private var height = OnboardingFormMetrics.controlHeight
  let horizontalPadding: CGFloat

  func body(content: Content) -> some View {
    content
      .textFieldStyle(.plain)
      .font(.onboardingIOSBody)
      .padding(.horizontal, horizontalPadding)
      .frame(height: height)
      .frame(maxWidth: .infinity)
      .background(.ultraThinMaterial, in: Capsule())
      .clipShape(Capsule())
  }
}

extension View {
  func onboardingFormField(horizontalPadding: CGFloat = 20) -> some View {
    modifier(OnboardingFormFieldModifier(horizontalPadding: horizontalPadding))
  }
}

struct OnboardingFormButtonStyle: PrimitiveButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @ScaledMetric(relativeTo: .body) private var height = OnboardingFormMetrics.controlHeight
  var tint: Color = .accentColor
  var foregroundColor: Color = .white

  @ViewBuilder
  func makeBody(configuration: Configuration) -> some View {
    if #available(iOS 26.0, *) {
      button(configuration)
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(surfaceColor)
        .frame(height: height)
        // Allow native glass press feedback; activation still uses the inherited state below.
        .environment(\.isEnabled, true)
        .accessibilityRepresentation {
          button(configuration)
            .buttonStyle(.plain)
            .disabled(!isEnabled)
        }
    } else {
      button(configuration)
        .buttonStyle(.plain)
        .frame(height: height)
        .background(surfaceColor, in: Capsule())
    }
  }

  private var surfaceColor: Color {
    isEnabled ? tint : Color(uiColor: .systemGray5)
  }

  private var labelColor: Color {
    isEnabled ? foregroundColor : Color(uiColor: .secondaryLabel)
  }

  private func button(_ configuration: Configuration) -> some View {
    let canActivate = isEnabled
    return Button(role: configuration.role) {
      guard canActivate else { return }
      configuration.trigger()
    } label: {
      configuration.label
        .font(.onboardingIOSBody)
        .foregroundStyle(labelColor)
        .tint(labelColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

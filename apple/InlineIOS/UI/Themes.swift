import SwiftUI

struct Default: ThemeConfig {
  var primaryTextColor: UIColor?

  var secondaryTextColor: UIColor?

  var id: String = "Default"

  var name: String = "Default"

  var backgroundColor: UIColor = .systemBackground

  var bubbleBackground: UIColor = .init(hex: "#52A5FF")!
  var incomingBubbleBackground: UIColor = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#27262B")!
    } else {
      UIColor(hex: "#F2F2F2")!
    }
  })

  var accent: UIColor = .init(hex: "#52A5FF")!
  var toastSuccess: UIColor?
  var toastFailed: UIColor?
  var toastInfo: UIColor?
  var deleteAction: UIColor? = .systemRed
}

struct Lavender: ThemeConfig {
  var primaryTextColor: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#CDD6F4")!
    } else {
      UIColor(hex: "#4C4F69")!
    }
  })

  var secondaryTextColor: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#696A85")!
    } else {
      UIColor(hex: "#BDC2D1")!
    }
  })

  var id: String = "lavender"

  var name: String = "Lavender"

  var backgroundColor: UIColor = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#1E1E2E")!
    } else {
      UIColor(hex: "#EFF1F5")!
    }
  })

  var bubbleBackground: UIColor = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#7A8AEF")!
    } else {
      UIColor(hex: "#7A8AEF")!
    }
  })
  var incomingBubbleBackground: UIColor = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#313244")!
    } else {
      UIColor(hex: "#E7E9EC")!
    }
  })

  var accent: UIColor = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#8293FF")!
    } else {
      UIColor(hex: "#8293FF")!
    }
  })
  var toastSuccess: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#A6E3A1")!
    } else {
      UIColor(hex: "#40A02B")!
    }
  })
  var toastFailed: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#F38BA8")!
    } else {
      UIColor(hex: "#D20F39")!
    }
  })
  var toastInfo: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#313244")!
    } else {
      UIColor(hex: "#E7E9EC")!
    }
  })
  var deleteAction: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#F38BA8")!
    } else {
      UIColor(hex: "#D20F39")!
    }
  })
}

struct PeonyPink: ThemeConfig {
  var primaryTextColor: UIColor?

  var secondaryTextColor: UIColor?

  var id: String = "PeonyPink"

  var name: String = "Peony Pink"

  var backgroundColor: UIColor = .systemBackground

  var bubbleBackground: UIColor = .init(hex: "#FF82B8")!
  var incomingBubbleBackground: UIColor = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#27262B")!
    } else {
      UIColor(hex: "#F2F2F2")!
    }
  })

  var accent: UIColor = .init(hex: "#FF82B8")!

  var toastSuccess: UIColor?
  var toastFailed: UIColor?
  var toastInfo: UIColor?
  var deleteAction: UIColor? = .init(hex: "#E91E63")!
}

struct Orchid: ThemeConfig {
  var primaryTextColor: UIColor?

  var secondaryTextColor: UIColor?

  var id: String = "Orchid"

  var name: String = "Orchid"

  var backgroundColor: UIColor = .systemBackground

  var bubbleBackground: UIColor = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#8b77dc")!
    } else {
      UIColor(hex: "#a28cf2")!
    }
  })
  var incomingBubbleBackground: UIColor = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#27262B")!
    } else {
      UIColor(hex: "#F2F2F2")!
    }
  })

  var accent: UIColor = .init(hex: "#a28cf2")!

  var toastSuccess: UIColor?
  var toastFailed: UIColor?
  var toastInfo: UIColor?
  var deleteAction: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#B794F6")! // Light purple for dark mode
    } else {
      UIColor(hex: "#805AD5")! // Darker purple for light mode
    }
  })
}

// MARK: - Theme Preview Components

struct ChatPreviewView: View {
  let theme: ThemeConfig

  var body: some View {
    VStack(spacing: 0) {
      // Navigation Bar
      HStack {
        Button(action: {}) {
          Image(systemName: "chevron.left")
            .font(.title2)
            .foregroundColor(Color(theme.accent))
        }

        HStack(spacing: 8) {
          Circle()
            .fill(Color(theme.accent))
            .frame(width: 32, height: 32)
            .overlay {
              Text("JD")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.white)
            }

          VStack(alignment: .leading, spacing: 1) {
            Text("John Doe")
              .font(.headline)
              .foregroundColor(.primary)
            Text("Online")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }

        Spacer()

        Button(action: {}) {
          Image(systemName: "phone")
            .font(.title3)
            .foregroundColor(Color(theme.accent))
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(Color(theme.backgroundColor))

      Divider()

      // Messages
      ScrollView {
        LazyVStack(spacing: 12) {
          // Incoming message with avatar
          HStack(alignment: .bottom, spacing: 8) {
            Circle()
              .fill(Color(theme.accent))
              .frame(width: 28, height: 28)
              .overlay {
                Text("JD")
                  .font(.caption2)
                  .fontWeight(.medium)
                  .foregroundColor(.white)
              }

            VStack(alignment: .leading, spacing: 4) {
              Text("John Doe")
                .font(.caption)
                .foregroundColor(.secondary)

              MessageBubble(
                text: "Hey! How's the new theme looking?",
                outgoing: false,
                theme: theme
              )
            }

            Spacer()
          }
          .padding(.horizontal, 16)

          // Outgoing message
          HStack {
            Spacer()
            MessageBubble(
              text: "It looks amazing! I love the color scheme 🎨",
              outgoing: true,
              theme: theme
            )
          }
          .padding(.horizontal, 16)

          // Incoming longer message
          HStack(alignment: .bottom, spacing: 8) {
            Circle()
              .fill(Color(theme.accent))
              .frame(width: 28, height: 28)
              .overlay {
                Text("JD")
                  .font(.caption2)
                  .fontWeight(.medium)
                  .foregroundColor(.white)
              }

            VStack(alignment: .leading, spacing: 4) {
              MessageBubble(
                text: "Perfect! The bubble colors really make the conversation feel more vibrant and engaging. Great work on this!",
                outgoing: false,
                theme: theme
              )
            }

            Spacer()
          }
          .padding(.horizontal, 16)

          // Outgoing short message
          HStack {
            Spacer()
            MessageBubble(
              text: "Thanks! 😊",
              outgoing: true,
              theme: theme
            )
          }
          .padding(.horizontal, 16)

          // System message style
          HStack {
            Spacer()
            Text("Today")
              .font(.caption)
              .foregroundColor(.secondary)
              .padding(.horizontal, 12)
              .padding(.vertical, 4)
              .background(Color.secondary.opacity(0.1))
              .clipShape(Capsule())
            Spacer()
          }
          .padding(.vertical, 8)

          // More messages to show variety
          HStack(alignment: .bottom, spacing: 8) {
            Circle()
              .fill(Color(theme.accent))
              .frame(width: 28, height: 28)
              .overlay {
                Text("JD")
                  .font(.caption2)
                  .fontWeight(.medium)
                  .foregroundColor(.white)
              }

            VStack(alignment: .leading, spacing: 4) {
              MessageBubble(
                text: "Should we ship this theme?",
                outgoing: false,
                theme: theme
              )
            }

            Spacer()
          }
          .padding(.horizontal, 16)

          HStack {
            Spacer()
            MessageBubble(
              text: "Absolutely! Let's do it 🚀",
              outgoing: true,
              theme: theme
            )
          }
          .padding(.horizontal, 16)
        }
        .padding(.vertical, 16)
      }
      .background(Color(theme.backgroundColor))

      // Compose area
      HStack(spacing: 12) {
        Button(action: {}) {
          Image(systemName: "plus")
            .font(.title3)
            .foregroundColor(Color(theme.accent))
        }

        HStack {
          Text("Message")
            .foregroundColor(.secondary)
          Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 20))

        Button(action: {}) {
          Image(systemName: "arrow.up.circle.fill")
            .font(.title2)
            .foregroundColor(Color(theme.accent))
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(Color(theme.backgroundColor))
    }
    .background(Color(theme.backgroundColor))
  }
}

struct MessageBubble: View {
  let text: String
  let outgoing: Bool
  let theme: ThemeConfig

  var body: some View {
    HStack {
      if outgoing { Spacer(minLength: 60) }

      Text(text)
        .font(.body)
        .foregroundColor(outgoing ? .white : Color(theme.primaryTextColor ?? .label))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
          outgoing ?
            Color(theme.bubbleBackground) :
            Color(theme.incomingBubbleBackground)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(alignment: .bottomTrailing) {
          if outgoing {
            HStack(spacing: 2) {
              Text("12:34")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.7))
              Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.7))
            }
            .padding(.trailing, 8)
            .padding(.bottom, 4)
          }
        }

      if !outgoing { Spacer(minLength: 60) }
    }
  }
}

// MARK: - Theme Previews

#Preview("Default Theme") {
  ChatPreviewView(theme: Default())
    .preferredColorScheme(.light)
}

#Preview("Default Theme - Dark") {
  ChatPreviewView(theme: Default())
    .preferredColorScheme(.dark)
}

#Preview("Lavender Theme") {
  ChatPreviewView(theme: Lavender())
    .preferredColorScheme(.light)
}

#Preview("Lavender Theme - Dark") {
  ChatPreviewView(theme: Lavender())
    .preferredColorScheme(.dark)
}

#Preview("Peony Pink Theme") {
  ChatPreviewView(theme: PeonyPink())
    .preferredColorScheme(.light)
}

#Preview("Peony Pink Theme - Dark") {
  ChatPreviewView(theme: PeonyPink())
    .preferredColorScheme(.dark)
}

#Preview("Orchid Theme") {
  ChatPreviewView(theme: Orchid())
    .preferredColorScheme(.light)
}

#Preview("Orchid Theme - Dark") {
  ChatPreviewView(theme: Orchid())
    .preferredColorScheme(.dark)
}

#Preview("All Themes Comparison") {
  ScrollView {
    LazyVStack(spacing: 20) {
      ForEach([Default(), Lavender(), PeonyPink(), Orchid()] as [any ThemeConfig], id: \.id) { theme in
        VStack(alignment: .leading, spacing: 8) {
          Text(theme.name)
            .font(.headline)
            .padding(.horizontal, 16)

          ChatPreviewView(theme: theme)
            .frame(height: 400)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
        }
      }
    }
    .padding(.vertical, 20)
  }
  .background(Color(.systemGroupedBackground))
}

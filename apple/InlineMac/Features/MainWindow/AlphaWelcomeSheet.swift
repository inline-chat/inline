import SwiftUI

struct AlphaWelcomeSheet: View {
  @Environment(\.dismiss) private var dismiss

  var firstName: String?

  private var greeting: String {
    if let firstName {
      return "Hey, \(firstName) —"
    }
    return "Hey there —"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 12) {
        Text("Welcome to Inline's Alpha")
          .font(.system(size: 23, weight: .semibold))
          .foregroundStyle(.primary)

        VStack(alignment: .leading, spacing: 10) {
          Text(greeting)
          Text("Welcome to Inline's alpha macOS app.")
          Text("We started working on Inline in September 2024, and even though we've spent a lot of time designing, building, and iterating, there's still a lot more to build and polish. We have imperfections, confusing bits, and possibly bugs that I apologize for in advance, but we're working hard every day to create the best experience possible for you.")
          Text("Can't wait for you to see what we've been building!")
          Text("Thank you,\nMo\nCo-founder of Inline.")
        }
        .font(.system(size: 15))
        .foregroundStyle(.primary)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 0) {
        Spacer()

        InlineButton(size: .large, style: .primary) {
          dismiss()
        } label: {
          Text("Continue")
            .frame(minWidth: 120)
            .padding(.horizontal, 12)
        }
        .keyboardShortcut(.defaultAction)

        Spacer()
      }
    }
    .padding(28)
    .frame(width: 460)
  }
}

#Preview {
  AlphaWelcomeSheet(firstName: "Mo")
}

import Foundation
import InlineProtocol

// MARK: - Formatting

/// Display strings for billing plans, shared by the macOS and iOS settings.
public enum BillingFormat {
  public static func planTitle(_ plan: String, interval: String) -> String {
    let name = switch plan {
    case "pro": "Pro"
    case "believer": "Believer"
    case "team": "Team"
    case "business": "Business"
    case "enterprise": "Enterprise"
    default: plan.capitalized
    }
    return switch interval {
    case "month": "\(name) Monthly"
    case "year": "\(name) Yearly"
    default: name
    }
  }

  public static func price(_ offer: BillingPlanOffer) -> String {
    let amount = dollars(offer.usdCents)
    let period = switch offer.interval {
    case "month": "month"
    case "year": "year"
    case "three_years": "3 years"
    default: ""
    }
    let unit = offer.perSeat ? " per member" : ""
    return period.isEmpty ? "\(amount)\(unit)" : "\(amount)\(unit) / \(period)"
  }

  public static func offerDescription(_ offer: BillingPlanOffer) -> String {
    switch (offer.plan, offer.interval) {
    case ("pro", "year"): "\(price(offer)) · two months free"
    case ("believer", _): "\(price(offer)) · Pro for people who want to back Inline"
    default: price(offer)
    }
  }

  public static func status(_ sub: BillingSubscription) -> String {
    let end = sub.hasPaidThrough ? date(sub.paidThrough) : nil
    var text: String = switch sub.funding {
    case "stripe":
      if sub.status == "past_due" {
        "Payment failed. Update your card to keep your plan."
      } else if sub.cancelAtPeriodEnd, let end {
        "Ends \(end)"
      } else if let end {
        "Renews \(end)"
      } else {
        "Active"
      }
    case "comp":
      end.map { "Complimentary until \($0)" } ?? "Complimentary"
    default:
      end.map { "Paid through \($0)" } ?? "Active"
    }
    if sub.seats > 1 { text += " · \(sub.seats) members" }
    return text
  }

  public static func wallet(_ wallet: BillingWallet) -> String {
    var parts: [String] = []
    if wallet.hasUsdCents { parts.append(dollars(wallet.usdCents, cents: true)) }
    if wallet.hasBtcSats {
      let btc = Double(wallet.btcSats) / 100_000_000
      parts.append(String(format: "%.8f BTC", btc))
    }
    return parts.joined(separator: " · ")
  }

  private static func dollars(_ cents: Int64, cents showCents: Bool = false) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.maximumFractionDigits = showCents || cents % 100 != 0 ? 2 : 0
    formatter.minimumFractionDigits = formatter.maximumFractionDigits
    return formatter.string(from: NSNumber(value: Double(cents) / 100)) ?? "$\(cents / 100)"
  }

  private static func date(_ seconds: Int64) -> String {
    Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(date: .abbreviated, time: .omitted)
  }
}

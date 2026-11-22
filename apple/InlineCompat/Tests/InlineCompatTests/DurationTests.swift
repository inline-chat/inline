import Foundation
@testable import InlineCompat
import Testing

/// Checks a compat duration against the native one for exact nanosecond values.
private func expectParity(
  _ compat: CompatDuration,
  _ native: Swift.Duration,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(compat.components.seconds == native.components.seconds, sourceLocation: sourceLocation)
  #expect(compat.components.attoseconds == native.components.attoseconds, sourceLocation: sourceLocation)
  #expect(CompatDuration(native) == compat, sourceLocation: sourceLocation)
  #expect(compat.swiftDuration == native, sourceLocation: sourceLocation)
}

/// Compat and native agree to within `tolerance` nanoseconds (for inexact doubles).
private func expectNear(
  _ compat: CompatDuration,
  _ native: Swift.Duration,
  tolerance: Int64 = 1,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  let difference = compat.nanosecondsValue - CompatDuration(native).nanosecondsValue
  #expect(abs(difference) <= tolerance, "compat \(compat) native \(native)", sourceLocation: sourceLocation)
}

private let nanosecondSamples: [Int64] = [
  0, 1, -1, 2, -2, 999, -999, 999_999_999, -999_999_999,
  1_000_000_000, -1_000_000_000, 1_000_000_001, -1_000_000_001,
  1_500_000_000, -1_500_000_000, 123_456_789_012, -123_456_789_012,
  86_400 * 1_000_000_000, -86_400 * 1_000_000_000,
  Int64.max, Int64.min + 1, Int64.min,
]

/// Small enough that sums, differences and small multiples never overflow.
private let arithmeticSamples: [Int64] = [
  0, 1, -1, 7, -7, 999_999_999, -999_999_999, 1_000_000_000, -1_000_000_000,
  1_500_000_000, -1_500_000_000, 123_456_789_012, -123_456_789_012,
]

@Suite("CompatDuration")
struct DurationTests {
  // MARK: Construction and components

  @Test("nanosecondsValue round-trips through components and Swift.Duration", arguments: nanosecondSamples)
  func parityForRawNanoseconds(_ nanoseconds: Int64) {
    let compat = CompatDuration(nanosecondsValue: nanoseconds)
    #expect(compat.nanosecondsValue == nanoseconds)
    expectParity(compat, .nanoseconds(nanoseconds))
    // components feed back into the component initializer losslessly.
    let (seconds, attoseconds) = compat.components
    #expect(CompatDuration(secondsComponent: seconds, attosecondsComponent: attoseconds) == compat)
  }

  @Test("components of negative durations share the duration's sign, like Swift.Duration")
  func negativeComponentSigns() {
    let compat = CompatDuration.milliseconds(-1500)
    #expect(compat.components.seconds == -1)
    #expect(compat.components.attoseconds == -500_000_000_000_000_000)
    #expect(compat.components == Swift.Duration.milliseconds(-1500).components)

    let subSecond = CompatDuration.nanoseconds(-1)
    #expect(subSecond.components.seconds == 0)
    #expect(subSecond.components.attoseconds == -1_000_000_000)
    #expect(subSecond.components == Swift.Duration.nanoseconds(-1).components)
  }

  @Test(
    "init(secondsComponent:attosecondsComponent:) matches Swift.Duration",
    arguments: [
      (Int64(0), Int64(0)), (1, 0), (-1, 0), (1, 500_000_000_000_000_000),
      (-1, -500_000_000_000_000_000), (1, -500_000_000_000_000_000), (-1, 500_000_000_000_000_000),
      (0, 999_999_999_999_999_999), (0, -999_999_999_999_999_999), (2, 3_000_000_000_000_000_000),
      (0, 1_000_000_000), (0, -1_000_000_000), (12, 345_678_901_000_000_000),
    ]
  )
  func componentInitializerParity(seconds: Int64, attoseconds: Int64) {
    let compat = CompatDuration(secondsComponent: seconds, attosecondsComponent: attoseconds)
    let native = Swift.Duration(secondsComponent: seconds, attosecondsComponent: attoseconds)
    // Sub-nanosecond attoseconds are truncated toward zero in both directions.
    #expect(compat == CompatDuration(native))
  }

  @Test("sub-nanosecond native durations truncate toward zero")
  func subNanosecondTruncation() {
    #expect(CompatDuration(Swift.Duration(secondsComponent: 1, attosecondsComponent: 1)) == .seconds(1))
    #expect(CompatDuration(Swift.Duration(secondsComponent: 0, attosecondsComponent: 999_999_999)) == .zero)
    #expect(CompatDuration(Swift.Duration(secondsComponent: 0, attosecondsComponent: -999_999_999)) == .zero)
    #expect(CompatDuration(Swift.Duration.nanoseconds(7) / 2) == .nanoseconds(3))
    #expect(CompatDuration(Swift.Duration.nanoseconds(-7) / 2) == .nanoseconds(-3))
  }

  @Test("zero")
  func zero() {
    #expect(CompatDuration.zero.nanosecondsValue == 0)
    #expect(CompatDuration.zero.swiftDuration == .zero)
    #expect(CompatDuration(Swift.Duration.zero) == .zero)
    #expect(CompatDuration.zero == .seconds(0))
  }

  // MARK: Factories

  @Test(
    "integer factories match Swift.Duration",
    arguments: [0, 1, -1, 7, -7, 999, -999, 1000, 1500, -1500, 86_400, -86_400, 1_000_000, 2_147_483_647, -2_147_483_648]
  )
  func integerFactoryParity(_ value: Int) {
    expectParity(.seconds(value), .seconds(value))
    expectParity(.milliseconds(value), .milliseconds(value))
    expectParity(.microseconds(value), .microseconds(value))
    expectParity(.nanoseconds(value), .nanoseconds(value))
  }

  @Test("integer factories accept any BinaryInteger")
  func integerFactoryTypes() {
    expectParity(.seconds(UInt8(3)), .seconds(UInt8(3)))
    expectParity(.milliseconds(Int32(-5)), .milliseconds(Int32(-5)))
    expectParity(.microseconds(UInt64(12_345)), .microseconds(UInt64(12_345)))
    expectParity(.nanoseconds(Int16(-321)), .nanoseconds(Int16(-321)))
    #expect(CompatDuration.seconds(Int64(2)) == .milliseconds(2000))
    #expect(CompatDuration.milliseconds(1) == .microseconds(1000))
    #expect(CompatDuration.microseconds(1) == .nanoseconds(1000))
  }

  @Test("double factories with exactly representable values match Swift.Duration")
  func exactDoubleFactoryParity() {
    for value in [0.0, 0.5, -0.5, 1.5, -1.5, 0.25, -0.25, 2.75, -2.75, 1024.0, -1024.0, 3600.125] {
      expectParity(.seconds(value), .seconds(value))
      expectParity(.milliseconds(value), .milliseconds(value))
      expectParity(.microseconds(value), .microseconds(value))
    }
  }

  @Test(
    "double factories with inexact values stay within 1ns of Swift.Duration",
    arguments: [0.1, -0.1, 0.001, -0.001, 1e-9, -1e-9, 1e-12, 123.456, -123.456, 0.3333333333, 98765.4321, -98765.4321, 1e6, 9e9]
  )
  func inexactDoubleFactoryParity(_ value: Double) {
    expectNear(.seconds(value), .seconds(value))
    expectNear(.milliseconds(value), .milliseconds(value))
    expectNear(.microseconds(value), .microseconds(value))
  }

  @Test("double factories truncate toward zero")
  func doubleFactoriesTruncate() {
    #expect(CompatDuration.seconds(1.9e-9) == .nanoseconds(1))
    #expect(CompatDuration.seconds(-1.9e-9) == .nanoseconds(-1))
    #expect(CompatDuration.milliseconds(0.0000009) == .zero)
    #expect(CompatDuration.microseconds(-0.0009) == .zero)
  }

  // MARK: Saturation

  @Test("doubles beyond the Int64 nanosecond range saturate instead of trapping")
  func saturation() {
    #expect(CompatDuration.seconds(Double.infinity).nanosecondsValue == .max)
    #expect(CompatDuration.seconds(-Double.infinity).nanosecondsValue == .min)
    #expect(CompatDuration.seconds(1e300).nanosecondsValue == .max)
    #expect(CompatDuration.seconds(-1e300).nanosecondsValue == .min)
    #expect(CompatDuration.milliseconds(Double.infinity).nanosecondsValue == .max)
    #expect(CompatDuration.milliseconds(-1e300).nanosecondsValue == .min)
    #expect(CompatDuration.microseconds(Double.greatestFiniteMagnitude).nanosecondsValue == .max)
    #expect(CompatDuration.microseconds(-Double.infinity).nanosecondsValue == .min)
    // Exactly at the edges: Double(Int64.max) rounds up to 2^63, which must not trap.
    #expect(CompatDuration.seconds(Double(Int64.max) / 1e9).nanosecondsValue == .max)
    #expect(CompatDuration.seconds(Double(Int64.min) / 1e9).nanosecondsValue == .min)
    // Just inside the range stays finite.
    let nearMax = CompatDuration.seconds(9.2e9)
    #expect(nearMax.nanosecondsValue == 9_200_000_000_000_000_000)
  }

  @Test("NaN produces zero, not an arbitrary extreme")
  func nanIsZero() {
    #expect(CompatDuration.seconds(Double.nan) == .zero)
    #expect(CompatDuration.milliseconds(-Double.nan) == .zero)
    #expect(CompatDuration.microseconds(Double.signalingNaN) == .zero)
    #expect(CompatDuration.seconds(1) * Double.nan == .zero)
    #expect(CompatDuration.zero / 0.0 == .zero)
    #expect(CompatDuration.zero * Double.infinity == .zero)
  }

  @Test("double multiplication and division saturate")
  func arithmeticSaturation() {
    let big = CompatDuration(nanosecondsValue: .max)
    #expect((big * 2.0).nanosecondsValue == .max)
    #expect((big * -2.0).nanosecondsValue == .min)
    #expect((CompatDuration.seconds(1) * Double.infinity).nanosecondsValue == .max)
    #expect((CompatDuration.seconds(1) * -Double.infinity).nanosecondsValue == .min)
    #expect((CompatDuration.seconds(1) / 0.0).nanosecondsValue == .max)
    #expect((CompatDuration.seconds(-1) / 0.0).nanosecondsValue == .min)
    #expect((CompatDuration.seconds(1) / 1e-300).nanosecondsValue == .max)
  }

  // MARK: Arithmetic

  @Test("addition, subtraction and negation match Swift.Duration")
  func additiveParity() {
    for lhs in arithmeticSamples {
      for rhs in arithmeticSamples {
        let a = CompatDuration.nanoseconds(lhs), b = CompatDuration.nanoseconds(rhs)
        let na = Swift.Duration.nanoseconds(lhs), nb = Swift.Duration.nanoseconds(rhs)
        expectParity(a + b, na + nb)
        expectParity(a - b, na - nb)
        var sum = a
        sum += b
        expectParity(sum, na + nb)
        var difference = a
        difference -= b
        expectParity(difference, na - nb)
      }
      // Swift.Duration has no prefix minus; compare against zero minus the value.
      expectParity(-CompatDuration.nanoseconds(lhs), .zero - Swift.Duration.nanoseconds(lhs))
    }
    #expect(-CompatDuration.zero == .zero)
    #expect(-(-CompatDuration.seconds(3)) == .seconds(3))
  }

  @Test("integer multiplication and division match Swift.Duration")
  func integerScalingParity() {
    for value in arithmeticSamples {
      let compat = CompatDuration.nanoseconds(value)
      let native = Swift.Duration.nanoseconds(value)
      for factor in [0, 1, -1, 2, -3, 7, 1000] {
        expectParity(compat * factor, native * factor)
        var scaled = compat
        scaled *= factor
        expectParity(scaled, native * factor)
      }
      for divisor in [1, -1, 2, -2, 3, 7, -7, 1000, 1_000_000_007] {
        // Swift.Duration keeps sub-nanosecond attoseconds; truncating them must give the
        // compat quotient.
        #expect(compat / divisor == CompatDuration(native / divisor), "\(value) / \(divisor)")
        var divided = compat
        divided /= divisor
        #expect(divided == CompatDuration(native / divisor))
      }
    }
    #expect(CompatDuration.seconds(1) * UInt8(3) == .seconds(3))
    #expect(CompatDuration.seconds(3) / Int16(2) == .milliseconds(1500))
  }

  @Test("double multiplication and division stay within 1ns of Swift.Duration")
  func doubleScalingParity() {
    for value in arithmeticSamples {
      let compat = CompatDuration.nanoseconds(value)
      let native = Swift.Duration.nanoseconds(value)
      for factor in [0.0, 1.0, -1.0, 0.5, -0.5, 1.5, 2.0, 0.1, 3.25, 1e-3] {
        expectNear(compat * factor, native * factor)
      }
      for divisor in [1.0, -1.0, 0.5, 2.0, 3.0, -4.0, 10.0, 1e3] {
        expectNear(compat / divisor, native / divisor)
      }
    }
    #expect(CompatDuration.seconds(2) * 0.25 == .milliseconds(500))
    #expect(CompatDuration.seconds(1) / 4.0 == .milliseconds(250))
  }

  @Test("duration / duration matches Swift.Duration")
  func ratioParity() {
    for lhs in arithmeticSamples {
      for rhs in arithmeticSamples where rhs != 0 {
        let compat = CompatDuration.nanoseconds(lhs) / CompatDuration.nanoseconds(rhs)
        let native = Swift.Duration.nanoseconds(lhs) / Swift.Duration.nanoseconds(rhs)
        #expect(abs(compat - native) <= abs(native) * 1e-12, "\(lhs) / \(rhs)")
      }
    }
    #expect(CompatDuration.seconds(3) / CompatDuration.seconds(2) == 1.5)
    #expect(CompatDuration.seconds(1) / CompatDuration.zero == .infinity)
    #expect((CompatDuration.zero / CompatDuration.zero).isNaN)
  }

  // MARK: Comparison, hashing, coding

  @Test("ordering matches Swift.Duration")
  func comparisonParity() {
    for lhs in nanosecondSamples {
      for rhs in nanosecondSamples {
        let a = CompatDuration.nanoseconds(lhs), b = CompatDuration.nanoseconds(rhs)
        let na = Swift.Duration.nanoseconds(lhs), nb = Swift.Duration.nanoseconds(rhs)
        #expect((a < b) == (na < nb))
        #expect((a <= b) == (na <= nb))
        #expect((a > b) == (na > nb))
        #expect((a >= b) == (na >= nb))
        #expect((a == b) == (na == nb))
      }
    }
    let sortedCompat = nanosecondSamples.shuffled().map(CompatDuration.nanoseconds).sorted()
    let sortedNative = nanosecondSamples.shuffled().map { Swift.Duration.nanoseconds($0) }.sorted()
    #expect(sortedCompat.map(\.swiftDuration) == sortedNative)
    #expect(max(CompatDuration.seconds(1), .milliseconds(1001)) == .milliseconds(1001))
    #expect(min(CompatDuration.seconds(-1), .milliseconds(-999)) == .seconds(-1))
  }

  @Test("equal durations from different units hash together")
  func hashing() {
    let set: Set<CompatDuration> = [
      .seconds(1), .milliseconds(1000), .microseconds(1_000_000), .nanoseconds(1_000_000_000),
      .seconds(1.0), .milliseconds(1000.0), CompatDuration(Swift.Duration.seconds(1)),
    ]
    #expect(set.count == 1)
    #expect(Set([CompatDuration.seconds(1), .seconds(-1), .zero]).count == 3)
  }

  @Test("Codable round trip")
  func codable() throws {
    let values = nanosecondSamples.map(CompatDuration.nanoseconds)
    let data = try JSONEncoder().encode(values)
    let decoded = try JSONDecoder().decode([CompatDuration].self, from: data)
    #expect(decoded == values)
  }

  @Test("description matches Swift.Duration for common values")
  func descriptionParity() {
    for nanoseconds: Int64 in [0, 1_000_000_000, -1_000_000_000, 1_500_000_000, -1_500_000_000, 250_000_000, -250_000_000, 60_000_000_000, 1] {
      #expect(CompatDuration.nanoseconds(nanoseconds).description == Swift.Duration.nanoseconds(nanoseconds).description)
    }
  }

  // MARK: Compat conversions

  @Test("compatTimeInterval and compatNonNegativeNanoseconds")
  func conversions() {
    #expect(CompatDuration.milliseconds(1500).compatTimeInterval == 1.5)
    #expect(CompatDuration.milliseconds(-250).compatTimeInterval == -0.25)
    #expect(CompatDuration.zero.compatTimeInterval == 0)
    #expect(CompatDuration.milliseconds(3).compatNonNegativeNanoseconds == 3_000_000)
    #expect(CompatDuration.nanoseconds(-1).compatNonNegativeNanoseconds == 0)
    #expect(CompatDuration(nanosecondsValue: .min).compatNonNegativeNanoseconds == 0)
    #expect(CompatDuration(nanosecondsValue: .max).compatNonNegativeNanoseconds == UInt64(Int64.max))
  }

  @Test("swiftDuration round trips for every sample", arguments: nanosecondSamples)
  func swiftDurationRoundTrip(_ nanoseconds: Int64) {
    let compat = CompatDuration(nanosecondsValue: nanoseconds)
    #expect(CompatDuration(compat.swiftDuration) == compat)
    let native = Swift.Duration.nanoseconds(nanoseconds)
    #expect(CompatDuration(native).swiftDuration == native)
  }
}

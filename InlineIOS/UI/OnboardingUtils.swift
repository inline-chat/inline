import Foundation

public class OnboardingUtils: @unchecked Sendable {
    public static var shared = OnboardingUtils()

    public var hPadding: CGFloat = 50
    public var buttonBottomPadding: CGFloat = 18

    public init() {}
}

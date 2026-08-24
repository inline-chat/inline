import InlineKit
import Testing

@Suite("Email address validation")
struct EmailAddressValidatorTests {
  @Test("accepts ordinary onboarding email addresses")
  func validAddresses() {
    #expect(EmailAddressValidator.isValid("person@example.com"))
    #expect(EmailAddressValidator.isValid("Person+work@sub.example.com"))
    #expect(EmailAddressValidator.isValid("first.last@example.co.uk"))
    #expect(EmailAddressValidator.isValid("person@xn--bcher-kva.example"))
  }

  @Test("rejects malformed onboarding email addresses")
  func invalidAddresses() {
    #expect(!EmailAddressValidator.isValid(""))
    #expect(!EmailAddressValidator.isValid("person"))
    #expect(!EmailAddressValidator.isValid("person@example"))
    #expect(!EmailAddressValidator.isValid("person @example.com"))
    #expect(!EmailAddressValidator.isValid("person@example.com\0"))
    #expect(!EmailAddressValidator.isValid("person@other@example.com"))
    #expect(!EmailAddressValidator.isValid("person..name@example.com"))
    #expect(!EmailAddressValidator.isValid(".person@example.com"))
    #expect(!EmailAddressValidator.isValid("person.@example.com"))
    #expect(!EmailAddressValidator.isValid("person@example..com"))
    #expect(!EmailAddressValidator.isValid("person@-example.com"))
    #expect(!EmailAddressValidator.isValid("person@example-.com"))
    #expect(!EmailAddressValidator.isValid("person@exam_ple.com"))
    #expect(!EmailAddressValidator.isValid("person@example.c"))
    #expect(!EmailAddressValidator.isValid("person@example.123"))
    let overlongAddress = String(repeating: "a", count: 310) + "@example.com"
    #expect(!EmailAddressValidator.isValid(overlongAddress))
  }
}

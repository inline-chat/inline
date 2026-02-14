import Testing

@testable import InlineConfig

@Suite("ProjectConfig argument parsing")
struct ProjectConfigTests {
  @Test("parses --key=value syntax")
  func parsesEqualsSyntax() {
    let value = ProjectConfig.getArgumentValue(
      for: .userProfile,
      in: ["inline", "--user-profile=work"]
    )

    #expect(value == "work")
  }

  @Test("parses --key value syntax")
  func parsesSeparatedSyntax() {
    let value = ProjectConfig.getArgumentValue(
      for: .userProfile,
      in: ["inline", "--user-profile", "work"]
    )

    #expect(value == "work")
  }

  @Test("treats bare flag as empty value")
  func parsesBareFlag() {
    let value = ProjectConfig.getArgumentValue(
      for: .userProfile,
      in: ["inline", "--user-profile"]
    )

    #expect(value == "")
  }

  @Test("keeps support for legacy concatenated syntax")
  func parsesLegacyConcatenatedSyntax() {
    let value = ProjectConfig.getArgumentValue(
      for: .userProfile,
      in: ["inline", "--user-profilework"]
    )

    #expect(value == "work")
  }

  @Test("returns nil when key is missing")
  func returnsNilForMissingKey() {
    let value = ProjectConfig.getArgumentValue(
      for: .userProfile,
      in: ["inline", "--other=value"]
    )

    #expect(value == nil)
  }
}

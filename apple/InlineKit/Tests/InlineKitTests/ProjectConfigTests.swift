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

  @Test("prefers env over argument over config for user profile")
  func resolvesUserProfilePrecedence() {
    #expect(
      ProjectConfig.resolvedUserProfile(
        envValue: "env",
        argValue: "arg",
        configValue: "config"
      ) == "env"
    )
    #expect(
      ProjectConfig.resolvedUserProfile(
        envValue: nil,
        argValue: "arg",
        configValue: "config"
      ) == "arg"
    )
    #expect(
      ProjectConfig.resolvedUserProfile(
        envValue: nil,
        argValue: nil,
        configValue: "config"
      ) == "config"
    )
    #expect(
      ProjectConfig.resolvedUserProfile(
        envValue: "",
        argValue: "",
        configValue: ""
      ) == nil
    )
  }
}

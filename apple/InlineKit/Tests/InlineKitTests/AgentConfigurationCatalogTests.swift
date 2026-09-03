import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Agent configuration catalog")
struct AgentConfigurationCatalogTests {
  @Test("catalog sections remain independently optional")
  func optionalSections() throws {
    let snapshot = try AgentConfigurationCatalogSnapshot(
      protocolCatalog: InlineProtocol.AgentConfigurationCatalog()
    )

    #expect(snapshot.projects == nil)
    #expect(snapshot.models == nil)
    #expect(snapshot.reasoning == nil)
    #expect(!snapshot.canSelectFolder)
  }

  @Test("typed choices preserve labels descriptions and model reasoning support")
  func typedChoices() throws {
    let catalog = InlineProtocol.AgentConfigurationCatalog.with {
      $0.projects = .with {
        $0.options = [
          .with {
            $0.id = "workspace-1"
            $0.label = "Inline"
            $0.description_p = "Local · Mo's Mac"
          }
        ]
        $0.canSelectFolder = true
        $0.defaultProjectID = "workspace-1"
      }
      $0.models = .with {
        $0.options = [
          .with {
            $0.id = "gpt-5.6-sol"
            $0.label = "5.6 Sol"
            $0.reasoningEffortIds = ["high"]
            $0.defaultReasoningEffortID = "high"
          }
        ]
        $0.defaultModelID = "gpt-5.6-sol"
      }
      $0.reasoning = .with {
        $0.options = [
          .with {
            $0.id = "high"
            $0.label = "High"
          }
        ]
      }
    }

    let snapshot = try AgentConfigurationCatalogSnapshot(protocolCatalog: catalog)

    #expect(snapshot.projects?.first?.label == "Inline")
    #expect(snapshot.projects?.first?.description == "Local · Mo's Mac")
    #expect(snapshot.models?.first?.reasoningEffortIDs == ["high"])
    #expect(snapshot.models?.first?.defaultReasoningEffortID == "high")
    #expect(snapshot.reasoning?.first?.label == "High")
    #expect(snapshot.defaultProjectID == "workspace-1")
    #expect(snapshot.defaultModelID == "gpt-5.6-sol")
    #expect(snapshot.defaultReasoningEffortID(forModelID: "gpt-5.6-sol") == "high")
    #expect(snapshot.canSelectFolder)
  }

  @Test("duplicate provider IDs are rejected")
  func rejectsDuplicates() {
    let catalog = InlineProtocol.AgentConfigurationCatalog.with {
      $0.projects = .with {
        $0.options = [
          .with {
            $0.id = "same"
            $0.label = "One"
          },
          .with {
            $0.id = "same"
            $0.label = "Two"
          },
        ]
      }
    }

    #expect(throws: AgentConfigurationCatalogError.self) {
      try AgentConfigurationCatalogSnapshot(protocolCatalog: catalog)
    }
  }

  @Test("default IDs must resolve to compatible typed choices")
  func rejectsInvalidDefaults() {
    let missingProject = InlineProtocol.AgentConfigurationCatalog.with {
      $0.projects = .with {
        $0.options = [
          .with {
            $0.id = "one"
            $0.label = "One"
          }
        ]
        $0.defaultProjectID = "missing"
      }
    }
    #expect(throws: AgentConfigurationCatalogError.self) {
      try AgentConfigurationCatalogSnapshot(protocolCatalog: missingProject)
    }

    let incompatibleReasoning = InlineProtocol.AgentConfigurationCatalog.with {
      $0.models = .with {
        $0.options = [
          .with {
            $0.id = "model"
            $0.label = "Model"
            $0.reasoningEffortIds = ["low"]
            $0.defaultReasoningEffortID = "high"
          }
        ]
        $0.defaultModelID = "model"
      }
      $0.reasoning = .with {
        $0.options = [
          .with {
            $0.id = "low"
            $0.label = "Low"
          },
          .with {
            $0.id = "high"
            $0.label = "High"
          },
        ]
      }
    }
    #expect(throws: AgentConfigurationCatalogError.self) {
      try AgentConfigurationCatalogSnapshot(protocolCatalog: incompatibleReasoning)
    }
  }
}

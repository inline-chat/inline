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
    #expect(snapshot.automaticModelTitle == "Use default — 5.6 Sol")
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

  @Test("missing default metadata keeps model and compatible reasoning choices available")
  func missingDefaultMetadata() throws {
    let catalog = InlineProtocol.AgentConfigurationCatalog.with {
      $0.models = .with {
        $0.options = [
          .with {
            $0.id = "gpt-6.1-sol"
            $0.label = "GPT-6.1 Sol"
            $0.reasoningEffortIds = ["high", "ultra"]
          },
          .with {
            $0.id = "future-model"
            $0.label = "Future model"
            $0.reasoningEffortIds = ["high", "future-effort"]
          },
        ]
      }
      $0.reasoning = .with {
        $0.options = [
          .with {
            $0.id = "high"
            $0.label = "High"
          },
          .with {
            $0.id = "ultra"
            $0.label = "Ultra"
          },
          .with {
            $0.id = "future-effort"
            $0.label = "Future effort"
          },
        ]
      }
    }
    let snapshot = try AgentConfigurationCatalogSnapshot(protocolCatalog: catalog)

    #expect(snapshot.defaultModelID == nil)
    #expect(snapshot.modelTitle(forModelID: nil) == "Automatic")
    #expect(snapshot.automaticModelTitle == "Use default")
    #expect(snapshot.reasoningOptions(forModelID: nil)?.map(\.id) == ["high"])
    #expect(snapshot.modelTitle(forModelID: "gpt-6.1-sol") == "GPT-6.1 Sol")
    #expect(snapshot.reasoningOptions(forModelID: "future-model")?.map(\.id) == ["high", "future-effort"])
    #expect(snapshot.modelTitle(forModelID: "uncatalogued-model") == "uncatalogued-model")
    #expect(snapshot.reasoningOptions(forModelID: "uncatalogued-model") == nil)
    #expect(snapshot.automaticReasoningTitle(forModelID: "uncatalogued-model") == "Use default")
    #expect(snapshot.compatibleReasoningEffortID("ultra", forModelID: nil) == nil)
    #expect(snapshot.compatibleReasoningEffortID("high", forModelID: nil) == "high")
    #expect(snapshot.compatibleReasoningEffortID(nil, forModelID: nil) == nil)
    #expect(snapshot.compatibleReasoningEffortID("future-effort", forModelID: "future-model") == "future-effort")
  }

  @Test("missing default metadata does not invent choices for an empty catalog")
  func emptyCatalogChoices() throws {
    let snapshot = try AgentConfigurationCatalogSnapshot(
      protocolCatalog: InlineProtocol.AgentConfigurationCatalog()
    )
    #expect(snapshot.modelTitle(forModelID: nil) == nil)
    #expect(snapshot.automaticModelTitle == nil)
    #expect(snapshot.reasoningOptions(forModelID: nil) == nil)
    #expect(snapshot.automaticReasoningTitle(forModelID: nil) == nil)
  }

  @Test("reasoning reset remains available when automatic models share no choices")
  func disjointReasoningChoices() throws {
    let catalog = InlineProtocol.AgentConfigurationCatalog.with {
      $0.models = .with {
        $0.options = [
          .with {
            $0.id = "one"
            $0.label = "One"
            $0.reasoningEffortIds = ["high"]
          },
          .with {
            $0.id = "two"
            $0.label = "Two"
            $0.reasoningEffortIds = ["low"]
          },
        ]
      }
      $0.reasoning = .with {
        $0.options = [
          .with {
            $0.id = "high"
            $0.label = "High"
          },
          .with {
            $0.id = "low"
            $0.label = "Low"
          },
        ]
      }
    }
    let snapshot = try AgentConfigurationCatalogSnapshot(protocolCatalog: catalog)
    #expect(snapshot.reasoningOptions(forModelID: nil)?.isEmpty == true)
    #expect(snapshot.automaticReasoningTitle(forModelID: nil) == "Use default")
    #expect(snapshot.compatibleReasoningEffortID("high", forModelID: nil) == nil)
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

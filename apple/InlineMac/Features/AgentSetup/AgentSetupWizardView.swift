import SwiftUI

struct AgentSetupWizardView: View {
  @Bindable var model: AgentSetupWizardModel
  @State private var showsReplacementConfirmation = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      AgentSetupWizardContentView(model: model)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      if model.showsActionFooter {
        Divider()

        AgentSetupWizardFooter(model: model) {
          showsReplacementConfirmation = true
        }
      }
    }
    .frame(minWidth: 540, minHeight: 420)
    .toolbar {
      AgentSetupWizardToolbar(
        canGoBack: model.canGoBack,
        documentationURL: model.documentationURL,
        onBack: model.goBack
      )
    }
    .alert(
      "Replace Existing Harness Setup?",
      isPresented: $showsReplacementConfirmation
    ) {
      Button("Replace and Retry", role: .destructive) {
        model.retryWithReplacement()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This may replace the selected harness’s existing Inline plugin or credential and bot mapping. "
          + "It will not delete bots or change other harnesses. Continue?"
      )
    }
  }
}

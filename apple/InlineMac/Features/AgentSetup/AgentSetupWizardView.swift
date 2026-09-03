import InlineCLIInstaller
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
    .agentSetupReplacementConfirmation(
      isPresented: $showsReplacementConfirmation,
      presentation: model.failure?.presentation,
      onConfirm: model.retryWithReplacement
    )
  }
}

extension View {
  func agentSetupReplacementConfirmation(
    isPresented: Binding<Bool>,
    presentation: AgentSetupFailurePresentation?,
    onConfirm: @escaping () -> Void
  ) -> some View {
    let title = presentation?.replacementConfirmationTitle ?? "Replace Existing Harness Setup?"
    let message = presentation?.replacementConfirmationMessage
      ?? "This may replace the selected harness’s existing Inline plugin or credential and bot mapping. It will not delete bots or change other harnesses. Continue?"
    let actionLabel = presentation?.replacementConfirmationActionLabel ?? "Replace and Retry"

    return alert(
      Text(verbatim: title),
      isPresented: isPresented
    ) {
      Button(actionLabel, role: .destructive, action: onConfirm)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(verbatim: message)
    }
  }
}

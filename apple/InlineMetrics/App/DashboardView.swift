import SwiftUI

struct DashboardView: View {
  @Bindable var store: MetricsStore
  @State private var email = ""
  @State private var password = ""
  @State private var code = ""
  @State private var showSample = false
  @FocusState private var focus: Field?
  private enum Field { case email, password, code }

  var body: some View {
    HStack(alignment: .top, spacing: 32) {
      VStack(alignment: .leading, spacing: 22) {
        VStack(alignment: .leading, spacing: 8) {
          Label("Inline Metrics", systemImage: "chart.xyaxis.line")
            .font(.system(size: 26, weight: .semibold, design: .rounded))
          Text("A little window into how Inline is growing.")
            .foregroundStyle(.secondary)
        }

        if store.isSignedIn {
          signedInControls
        } else {
          signInForm
        }

        if let error = store.errorMessage {
          Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }

        Spacer(minLength: 0)
        VStack(alignment: .leading, spacing: 8) {
          Text("ADD IT TO YOUR DESKTOP").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          Text("Right-click your desktop → Edit Widgets → Inline Metrics. Choose a size and drag it onto your desktop.")
            .font(.callout).fixedSize(horizontal: false, vertical: true)
          Text("Checks for new data about every 5 minutes while running in the menu bar, and after your Mac wakes. macOS decides when to redraw the widget.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          Toggle("Open at login", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
            .toggleStyle(.switch).controlSize(.small)
        }
      }
      .frame(width: 340)

      VStack(spacing: 14) {
        MetricsCard(snapshot: showSample ? .sample : store.snapshot, size: .large, isPreview: showSample)
          .padding(20)
          .frame(width: 292, height: 354)
          .background(.background, in: RoundedRectangle(cornerRadius: 24))
          .overlay(RoundedRectangle(cornerRadius: 24).stroke(.primary.opacity(0.06)))
          .shadow(color: .black.opacity(0.06), radius: 20, y: 8)
        Toggle("Preview with sample data", isOn: $showSample)
          .font(.caption).toggleStyle(.checkbox)
        if showSample {
          Text("Sample numbers are only shown here.")
            .font(.caption2).foregroundStyle(.secondary)
        }
      }
    }
    .padding(32)
    .frame(width: 760, height: 580)
    .background(Color(nsColor: .underPageBackgroundColor))
  }

  private var signInForm: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Sign in with your Inline admin account.").font(.callout)
      TextField("Email", text: $email)
        .textContentType(.username).focused($focus, equals: .email)
        .onSubmit { focus = .password }
      SecureField("Admin password", text: $password)
        .textContentType(.password).focused($focus, equals: .password)
        .onSubmit { focus = .code }
      TextField("Authenticator code", text: $code)
        .textContentType(.oneTimeCode).focused($focus, equals: .code)
        .onSubmit { signIn() }
      Button(action: signIn) {
        HStack {
          if store.isBusy { ProgressView().controlSize(.small) }
          Text(store.isBusy ? "Signing in…" : "Sign In")
        }.frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent).disabled(!canSignIn)
      Link("Set up your admin account ↗", destination: AdminClient.origin).font(.caption)
      Text("Your password is never saved. Admin sessions last up to 3 days; you can sign in again here.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    .textFieldStyle(.roundedBorder)
    .controlSize(.large)
    .disabled(store.isBusy)
  }

  private var signedInControls: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Connected to Inline Admin", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
      if let date = store.snapshot.metrics?.reportedAt {
        Text("Last updated \(date.formatted(date: .abbreviated, time: .shortened))")
          .font(.callout).foregroundStyle(.secondary)
      }
      HStack {
        Button(store.isBusy ? "Refreshing…" : "Refresh Now") { Task { await store.refresh() } }
          .buttonStyle(.borderedProminent)
        Button("Sign Out") { Task { await store.signOut() } }
      }.disabled(store.isBusy)
      Link("Open full dashboard ↗", destination: AdminClient.origin).font(.callout)
      Text("Daily metrics use UTC. Red and green changes compare today so far with all of yesterday. Weekly active means users active on 3+ days; historical comparisons for weekly active and waitlist aren’t available from this API.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  private var canSignIn: Bool {
    !store.isBusy && email.contains("@") && !password.isEmpty && code.count >= 6
  }

  private func signIn() {
    guard canSignIn else { return }
    let submittedPassword = password
    let submittedCode = code
    password = ""
    code = ""
    Task { await store.signIn(email: email, password: submittedPassword, code: submittedCode) }
  }
}

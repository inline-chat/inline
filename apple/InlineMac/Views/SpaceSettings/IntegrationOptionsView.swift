import Auth
import InlineKit
import SwiftUI

struct IntegrationOptionsView: View {
  let spaceId: Int64
  let provider: String

  @Environment(\.dismiss) private var dismiss

  @State private var selectedDatabase: String?
  @State private var databases: [NotionSimplifiedDatabase] = []
  @State private var selectedTeamId: String?
  @State private var teams: [LinearTeam] = []
  @State private var isLoading = false
  @State private var errorMessage: String?
  @State private var lastLoadedAt: Date?
  @State private var didLoadFromCache = false
  @State private var hadStaleCachedSelection = false

  private let databasesCacheKey: String
  private let selectedDatabaseCacheKey: String
  private let teamsCacheKey: String
  private let selectedTeamCacheKey: String

  init(spaceId: Int64, provider: String) {
    self.spaceId = spaceId
    self.provider = provider
    databasesCacheKey = "notion_databases_\(spaceId)"
    selectedDatabaseCacheKey = "notion_selected_database_\(spaceId)"
    teamsCacheKey = "linear_teams_\(spaceId)"
    selectedTeamCacheKey = "linear_selected_team_\(spaceId)"
  }

  var body: some View {
    Form {
      if provider == "notion" {
        Section("Notion Database") {
          Text("Choose the database where Inline should create \"Will Do\" tasks for this space. Changes save automatically.")
            .font(.footnote)
            .foregroundStyle(.secondary)

          Picker("Database", selection: $selectedDatabase) {
            Text("Select a database")
              .tag(nil as String?)
              .disabled(true)
            ForEach(databases, id: \.id) { database in
              Text("\(database.icon ?? "📄") \(database.title)")
                .tag(database.id as String?)
            }
          }
          .pickerStyle(.menu)
          .onChange(of: selectedDatabase ?? "") { _, newValue in
            guard !newValue.isEmpty else { return }
            cacheNotionSelection(newValue)
            saveNotionSelection(newValue)
          }
        }
      } else if provider == "linear" {
        Section("Default team") {
          Text("Required. Choose where Inline should create new issues for this space. Changes save automatically.")
            .font(.footnote)
            .foregroundStyle(.secondary)

          Picker("Team", selection: $selectedTeamId) {
            Text("Select a team")
              .tag(nil as String?)
              .disabled(true)
            ForEach(teams, id: \.id) { team in
              Text("\(team.name) (\(team.key))")
                .tag(team.id as String?)
            }
          }
          .pickerStyle(.menu)
          .onChange(of: selectedTeamId ?? "") { _, newValue in
            guard !newValue.isEmpty else { return }
            cacheLinearSelection(newValue)
            saveLinearSelection(newValue)
          }

          Text(linearSelectionSummary)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)

          if !isLoading, teams.isEmpty {
            Text("No teams found. Make sure Linear is connected for this space.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      }

      if let errorMessage {
        Section {
          Text(errorMessage)
            .foregroundStyle(.red)
        }
      }

      Section {
        statusRow
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .navigationTitle(provider == "linear" ? "Linear Options" : "Notion Options")
    .frame(minWidth: 380, minHeight: 240)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") {
          dismiss()
        }
      }
    }
    .task {
      loadCachedData()
      await refresh()
    }
  }

  private var statusRow: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
        .opacity(isLoading ? 1 : 0)

      Text(statusText)
        .font(.footnote)
        .foregroundStyle(.secondary)

      Spacer()

      if errorMessage != nil {
        Button("Try Again") {
          Task { await refresh() }
        }
        .buttonStyle(.link)
      }
    }
  }

  private var statusText: String {
    if isLoading {
      return provider == "linear" ? "Updating teams..." : "Updating databases..."
    }
    if let lastLoadedAt {
      return "Updated \(lastLoadedAt.formatted(date: .abbreviated, time: .shortened))"
    }
    if didLoadFromCache {
      return "Showing cached results"
    }
    return provider == "linear" ? "Loading teams..." : "Loading databases..."
  }

  private var linearSelectionSummary: String {
    guard provider == "linear" else { return "" }
    if hadStaleCachedSelection {
      return "Your previous selection wasn't saved for this space. Select a team again."
    }
    guard let selectedTeamId, !selectedTeamId.isEmpty else {
      return "Select a team to enable \"Create Linear Issue\"."
    }
    guard let team = teams.first(where: { $0.id == selectedTeamId }) else {
      return "Default team selected"
    }
    return "Issues will be created in \(team.name) (\(team.key))."
  }

  private func cacheNotionSelection(_ value: String) {
    UserDefaults.standard.set(value, forKey: selectedDatabaseCacheKey)
  }

  private func saveNotionSelection(_ newValue: String) {
    Task {
      do {
        _ = try await ApiClient.shared.saveNotionDatabaseId(spaceId: spaceId, databaseId: newValue)
      } catch {
        await MainActor.run {
          errorMessage = "Failed to save selection: \(error.localizedDescription)"
          selectedDatabase = UserDefaults.standard.string(forKey: selectedDatabaseCacheKey)
        }
      }
    }
  }

  private func cacheLinearSelection(_ value: String) {
    UserDefaults.standard.set(value, forKey: selectedTeamCacheKey)
  }

  private func saveLinearSelection(_ newValue: String) {
    Task {
      do {
        _ = try await ApiClient.shared.saveLinearTeamId(spaceId: spaceId, teamId: newValue)
      } catch {
        await MainActor.run {
          errorMessage = "Failed to save selection: \(error.localizedDescription)"
          selectedTeamId = UserDefaults.standard.string(forKey: selectedTeamCacheKey)
        }
      }
    }
  }

  private func loadCachedData() {
    var loadedDatabasesFromCache = false
    var loadedTeamsFromCache = false

    if let cachedData = UserDefaults.standard.data(forKey: databasesCacheKey),
       let decoded = try? JSONDecoder().decode([NotionSimplifiedDatabase].self, from: cachedData)
    {
      databases = decoded
      loadedDatabasesFromCache = true
    }
    selectedDatabase = UserDefaults.standard.string(forKey: selectedDatabaseCacheKey)

    if let cachedTeamsData = UserDefaults.standard.data(forKey: teamsCacheKey),
       let decodedTeams = try? JSONDecoder().decode([LinearTeam].self, from: cachedTeamsData)
    {
      teams = decodedTeams
      loadedTeamsFromCache = true
    }
    if provider == "linear" {
      // Prefer server truth; cached selection can be stale and misleading.
      selectedTeamId = nil
    } else {
      selectedTeamId = UserDefaults.standard.string(forKey: selectedTeamCacheKey)
    }

    switch provider {
    case "notion":
      didLoadFromCache = loadedDatabasesFromCache
    case "linear":
      didLoadFromCache = loadedTeamsFromCache
    default:
      didLoadFromCache = loadedDatabasesFromCache || loadedTeamsFromCache
    }
  }

  private func fetchDatabases() async {
    await MainActor.run { isLoading = true }
    do {
      let fetched = try await ApiClient.shared.getNotionDatabases(spaceId: spaceId)
      if let encoded = try? JSONEncoder().encode(fetched) {
        UserDefaults.standard.set(encoded, forKey: databasesCacheKey)
      }
      await MainActor.run {
        databases = fetched
        lastLoadedAt = Date()
      }
    } catch {
      await MainActor.run {
        errorMessage = "Unable to load databases: \(error.localizedDescription)"
      }
    }
    await MainActor.run { isLoading = false }
  }

  private func fetchTeams() async {
    await MainActor.run { isLoading = true }
    do {
      let fetched = try await ApiClient.shared.getLinearTeams(spaceId: spaceId)
      if let encoded = try? JSONEncoder().encode(fetched) {
        UserDefaults.standard.set(encoded, forKey: teamsCacheKey)
      }
      await MainActor.run {
        teams = fetched
        lastLoadedAt = Date()
      }
    } catch {
      await MainActor.run {
        errorMessage = "Unable to load teams: \(error.localizedDescription)"
      }
    }
    await MainActor.run { isLoading = false }
  }

  private func fetchCurrentLinearSelection() async {
    do {
      let integrations = try await ApiClient.shared.getIntegrations(
        userId: Auth.shared.getCurrentUserId() ?? 0,
        spaceId: spaceId
      )
      await MainActor.run {
        hadStaleCachedSelection = false
        if let teamId = integrations.linearTeamId, !teamId.isEmpty {
          selectedTeamId = teamId
          cacheLinearSelection(teamId)
        } else {
          if UserDefaults.standard.string(forKey: selectedTeamCacheKey)?.isEmpty == false {
            hadStaleCachedSelection = true
          }
          selectedTeamId = nil
          UserDefaults.standard.removeObject(forKey: selectedTeamCacheKey)
        }
      }
    } catch {
      // best-effort; keep cached selection
    }
  }

  private func refresh() async {
    await MainActor.run { errorMessage = nil }
    if provider == "notion" {
      await fetchDatabases()
    } else if provider == "linear" {
      async let teamsTask: Void = fetchTeams()
      async let selectionTask: Void = fetchCurrentLinearSelection()
      _ = await (teamsTask, selectionTask)
    }
  }
}

#Preview {
  IntegrationOptionsView(spaceId: 1, provider: "notion")
}

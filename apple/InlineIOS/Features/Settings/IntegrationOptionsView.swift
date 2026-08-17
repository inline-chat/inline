import Auth
import InlineKit
import SwiftUI

struct IntegrationOptionsView: View {
  var spaceId: Int64
  var provider: String
  @State private var selectedDatabase: String? = nil
  @State private var databases: [NotionSimplifiedDatabase] = []
  @State private var selectedTeam: String? = nil
  @State private var teams: [LinearTeam] = []
  @State private var isLoading = false
  @State private var errorMessage: String?
  @State private var saveTask: Task<Void, Never>?

  // Cache keys
  private let databasesCacheKey: String
  private let selectedDatabaseCacheKey: String
  private let teamsCacheKey: String
  private let selectedTeamCacheKey: String

  init(spaceId: Int64, provider: String) {
    self.spaceId = spaceId
    self.provider = provider
    // Create unique cache keys for this space
    databasesCacheKey = "notion_databases_\(spaceId)"
    selectedDatabaseCacheKey = "notion_selected_database_\(spaceId)"
    teamsCacheKey = "linear_teams_\(spaceId)"
    selectedTeamCacheKey = "linear_selected_team_\(spaceId)"
  }

  var body: some View {
    List {
      if provider == "linear" {
        Section(footer: Text("Choose where Inline should create issues for this space.")) {
          Picker("Default Team", selection: linearSelection) {
            Text("Select a team").tag(nil as String?)
            ForEach(teams, id: \.id) { team in
              Text("\(team.name) (\(team.key))")
                .tag(team.id as String?)
            }
          }
        }
      } else {
        Section(footer: Text("Choose where Inline should create tasks for this space.")) {
          Picker("Notion Source", selection: notionSelection) {
            Text("Select a Notion source").tag(nil as String?)
            ForEach(databases, id: \.id) { database in
              Text("\(database.icon ?? "📄") \(database.title)")
                .tag(database.id as String?)
            }
          }
        }
      }

      if isLoading {
        ProgressView()
          .frame(maxWidth: .infinity)
      }

      if let errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
      }
    }
    .listStyle(.insetGrouped)
    .onAppear {
      loadCachedData()

      Task {
        if provider == "linear" {
          await fetchTeams()
        } else {
          await fetchDatabases()
        }
        await fetchCurrentSelection()
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(id: "integration-options", placement: .principal) {
        HStack {
          if provider == "notion" || provider == "linear" {
            Image(provider == "linear" ? "linear-icon" : "notion-logo")
              .resizable()
              .frame(width: 24, height: 24)
              .padding(.trailing, 4)

            VStack(alignment: .leading) {
              Text(provider == "linear" ? "Linear" : "Notion")
                .font(.body)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
            }
          } else {
            Text("Integration Options")
              .foregroundColor(.primary)
          }
        }
      }
    }
  }

  private var notionSelection: Binding<String?> {
    Binding(
      get: { selectedDatabase },
      set: { value in
        selectedDatabase = value
        guard let value, !value.isEmpty else { return }
        UserDefaults.standard.set(value, forKey: selectedDatabaseCacheKey)
        enqueueSave { await saveNotionDatabase(value) }
      }
    )
  }

  private var linearSelection: Binding<String?> {
    Binding(
      get: { selectedTeam },
      set: { value in
        selectedTeam = value
        guard let value, !value.isEmpty else { return }
        UserDefaults.standard.set(value, forKey: selectedTeamCacheKey)
        enqueueSave { await saveLinearTeam(value) }
      }
    )
  }

  private func loadCachedData() {
    if let cachedData = UserDefaults.standard.data(forKey: databasesCacheKey),
       let decodedDatabases = try? JSONDecoder().decode([NotionSimplifiedDatabase].self, from: cachedData)
    {
      databases = decodedDatabases
    }

    // Lists may be cached, but the saved target always comes from the server.
    selectedDatabase = nil

    if let cachedData = UserDefaults.standard.data(forKey: teamsCacheKey),
       let decodedTeams = try? JSONDecoder().decode([LinearTeam].self, from: cachedData)
    {
      teams = decodedTeams
    }
    selectedTeam = nil
  }

  private func fetchDatabases() async {
    await MainActor.run { isLoading = true }
    defer { Task { @MainActor in isLoading = false } }
    do {
      let fetchedDatabases = try await InlineRPCClient.shared.notionDatabases(spaceID: spaceId)

      if !areDatabasesEqual(fetchedDatabases, databases) {
        if let encodedData = try? JSONEncoder().encode(fetchedDatabases) {
          UserDefaults.standard.set(encodedData, forKey: databasesCacheKey)
        }

        await MainActor.run {
          databases = fetchedDatabases
        }
      }
    } catch {
      await MainActor.run { errorMessage = "Couldn’t load Notion sources." }
    }
  }

  private func fetchTeams() async {
    await MainActor.run { isLoading = true }
    defer { Task { @MainActor in isLoading = false } }
    do {
      let fetchedTeams = try await InlineRPCClient.shared.linearTeams(spaceID: spaceId)
      if let encodedData = try? JSONEncoder().encode(fetchedTeams) {
        UserDefaults.standard.set(encodedData, forKey: teamsCacheKey)
      }
      await MainActor.run { teams = fetchedTeams }
    } catch {
      await MainActor.run { errorMessage = "Couldn’t load Linear teams." }
    }
  }

  private func fetchCurrentSelection() async {
    do {
      let integrations = try await InlineRPCClient.shared.integrations(
        userID: Auth.shared.getCurrentUserId() ?? 0,
        spaceID: spaceId
      )

      await MainActor.run {
        if provider == "linear" {
          if let teamID = integrations.linearTeamId, !teamID.isEmpty {
            selectedTeam = teamID
            UserDefaults.standard.set(teamID, forKey: selectedTeamCacheKey)
          } else {
            selectedTeam = nil
            UserDefaults.standard.removeObject(forKey: selectedTeamCacheKey)
          }
        } else if let sourceID = integrations.notionDatabaseId, !sourceID.isEmpty {
          selectedDatabase = sourceID
          UserDefaults.standard.set(sourceID, forKey: selectedDatabaseCacheKey)
        } else {
          selectedDatabase = nil
          UserDefaults.standard.removeObject(forKey: selectedDatabaseCacheKey)
        }
      }
    } catch {
      await MainActor.run {
        selectedDatabase = nil
        selectedTeam = nil
      }
    }
  }

  private func saveNotionDatabase(_ databaseID: String) async {
    do {
      try await InlineRPCClient.shared.setNotionDatabase(spaceID: spaceId, databaseID: databaseID)
      await MainActor.run {
        errorMessage = nil
        NotificationCenter.default.post(name: .connectorConfigurationUpdated, object: nil)
      }
    } catch {
      await MainActor.run {
        if selectedDatabase == databaseID {
          errorMessage = "Couldn’t save the Notion source."
          selectedDatabase = nil
          UserDefaults.standard.removeObject(forKey: selectedDatabaseCacheKey)
        }
      }
    }
  }

  private func saveLinearTeam(_ teamID: String) async {
    do {
      try await InlineRPCClient.shared.setLinearTeam(spaceID: spaceId, teamID: teamID)
      await MainActor.run {
        errorMessage = nil
        NotificationCenter.default.post(name: .connectorConfigurationUpdated, object: nil)
      }
    } catch {
      await MainActor.run {
        if selectedTeam == teamID {
          errorMessage = "Couldn’t save the Linear team."
          selectedTeam = nil
          UserDefaults.standard.removeObject(forKey: selectedTeamCacheKey)
        }
      }
    }
  }

  private func enqueueSave(_ operation: @escaping @MainActor () async -> Void) {
    let previous = saveTask
    saveTask = Task { @MainActor in
      await previous?.value
      await operation()
    }
  }

  private func areDatabasesEqual(_ db1: [NotionSimplifiedDatabase], _ db2: [NotionSimplifiedDatabase]) -> Bool {
    guard db1.count == db2.count else { return false }

    let ids1 = Set(db1.map(\.id))
    let ids2 = Set(db2.map(\.id))

    return ids1 == ids2
  }
}

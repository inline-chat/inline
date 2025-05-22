import InlineKit
import SwiftUI

struct IntegrationOptionsView: View {
  var spaceId: Int64
  var provider: String
  @State private var selectedDatabase: String? = nil
  @State private var databases: [NotionSimplifiedDatabase] = []

  // Cache keys
  private let databasesCacheKey: String
  private let selectedDatabaseCacheKey: String

  init(spaceId: Int64, provider: String) {
    self.spaceId = spaceId
    self.provider = provider
    // Create unique cache keys for this space
    databasesCacheKey = "notion_databases_\(spaceId)"
    selectedDatabaseCacheKey = "notion_selected_database_\(spaceId)"
  }

  var body: some View {
    List {
      // TODO: make footer better
      Section(footer: Text("Select a database to help AI understand your data")) {
        Picker("Database", selection: $selectedDatabase) {
          Text("Select a database").tag(nil as String?)
          ForEach(databases, id: \.id) { database in
            Text("\(database.icon ?? "📄") \(database.title)")
              .tag(database.id as String?)
          }
        }
        .animation(.default, value: selectedDatabase)
        .onChange(of: selectedDatabase ?? "") { _, newValue in
          UserDefaults.standard.set(newValue, forKey: selectedDatabaseCacheKey)
          Task {
            do {
              _ = try await ApiClient.shared.saveNotionDatabaseId(spaceId: spaceId, databaseId: newValue)
            } catch {
              print("Error saving notion database id: \(error)")
              DispatchQueue.main.async {
                selectedDatabase = UserDefaults.standard.string(forKey: selectedDatabaseCacheKey)
              }
            }
          }
        }
      }
    }
    .onAppear {
      loadCachedData()

      Task(priority: .background) {
        await fetchDatabases()
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(id: "integration-options", placement: .principal) {
        HStack {
          if provider == "notion" {
            Image("notion-logo")
              .resizable()
              .frame(width: 24, height: 24)
              .padding(.trailing, 4)

            VStack(alignment: .leading) {
              Text("Notion")
                .font(.body)
                .fontWeight(.semibold)
            }
          } else {
            // TODO: support Linear
            Text("Integration Options")
          }
        }
      }
    }
  }

  private func loadCachedData() {
    if let cachedData = UserDefaults.standard.data(forKey: databasesCacheKey),
       let decodedDatabases = try? JSONDecoder().decode([NotionSimplifiedDatabase].self, from: cachedData)
    {
      databases = decodedDatabases
    }

    selectedDatabase = UserDefaults.standard.string(forKey: selectedDatabaseCacheKey)
  }

  private func fetchDatabases() async {
    do {
      let fetchedDatabases = try await ApiClient.shared.getNotionDatabases(spaceId: spaceId)

      if !areDatabasesEqual(fetchedDatabases, databases) {
        if let encodedData = try? JSONEncoder().encode(fetchedDatabases) {
          UserDefaults.standard.set(encodedData, forKey: databasesCacheKey)
        }

        DispatchQueue.main.async {
          databases = fetchedDatabases
        }
      }
    } catch {
      print("Error fetching databases: \(error)")
    }
  }

  private func areDatabasesEqual(_ db1: [NotionSimplifiedDatabase], _ db2: [NotionSimplifiedDatabase]) -> Bool {
    guard db1.count == db2.count else { return false }

    let ids1 = Set(db1.map(\.id))
    let ids2 = Set(db2.map(\.id))

    return ids1 == ids2
  }
}

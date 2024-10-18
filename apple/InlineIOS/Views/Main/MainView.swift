import InlineKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject var nav: Navigation
    @Environment(\.appDatabase) var database

    @State var user: User? = nil
    @State var showSheet: Bool = false

    var body: some View {
        VStack {
            
        }
            .onAppear {
                Task {
                    do {
                        try await database.dbWriter.write { db in
                            if let id = Auth.shared.getCurrentUserId() {
                                let fetchedUser = try User.fetchOne(db, id: id)
                                if let user = fetchedUser {
                                    self.user = user
                                }
                            }
                        }
                    } catch {
                        Log.shared.error("Failed to get user", error: error)
                    }
                }
            }
            .toolbar(content: {
                ToolbarItem(placement: .principal) {
                    HStack {
                        Circle()
                            .fill(Color(.systemGray6))
                            .frame(width: 28)
                            .overlay(alignment: .center) {
                                Text("🐱")
                                    .font(.body)
                            }
                            .padding(.trailing, 6)
                        Text(user?.firstName ?? "Home")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Create Space") {
                            showSheet = true
                        }
                        Button("Logout", role: .destructive) {
                            Auth.shared.saveToken(nil)
                            do {
                                try AppDatabase.clearDB()
                            } catch {
                                Log.shared.error("Failed to delete DB and logout", error: error)
                            }
                            nav.popToRoot()
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .tint(Color.secondary)
                    }
                }
            })
            .navigationBarBackButtonHidden()
            .sheet(isPresented: $showSheet) {
                CreateSpace(showSheet: $showSheet)
                    .presentationBackground(.thinMaterial)
                    .presentationCornerRadius(28)
            }
    }
}

#Preview {
    MainView()
        .environmentObject(Navigation())
}

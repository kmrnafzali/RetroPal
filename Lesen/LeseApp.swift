import SwiftUI

@main
struct LeseApp: App {
    @StateObject private var library = Library()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .onOpenURL { url in
                    library.importBook(from: url)
                }
        }
    }
}

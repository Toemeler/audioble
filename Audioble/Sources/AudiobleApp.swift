import SwiftUI

@main
struct AudiobleApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(LibraryStore.shared)
                .environmentObject(PlayerEngine.shared)
                .tint(Theme.accent)
                .onOpenURL { url in
                    // "Copy to Audioble" from the share sheet, or a zip opened
                    // from the Files app.
                    Task { @MainActor in LibraryStore.shared.importArchive(at: url) }
                }
        }
    }
}

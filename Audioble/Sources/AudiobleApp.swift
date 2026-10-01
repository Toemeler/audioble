import SwiftUI

@main
struct AudiobleApp: App {
    init() {
        // Before any view exists: the Cast button needs the context, and a
        // cast session still running from the last launch is resumed by it.
        CastManager.shared.startIfNeeded()
    }

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

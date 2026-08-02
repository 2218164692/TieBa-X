import Foundation
import SwiftUI

@main
struct TiebaPureApp: App {
    @StateObject private var environment = AppEnvironment.live()
    @StateObject private var appearanceStore = AppAppearanceStore.live()
    @StateObject private var readingPreferencesStore = ReadingPreferencesStore.live()

    var body: some Scene {
        WindowGroup {
            Group {
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("UITEST_REMOTE_IMAGE_REUSE") {
                    RemoteImageReuseUITestHost()
                } else if ProcessInfo.processInfo.arguments.contains("UITEST_READER_MEDIA_POLICY") {
                    ReaderMediaPolicyUITestHost()
                } else if ProcessInfo.processInfo.arguments.contains("UITEST_IMAGE_VIEWER") {
                    ImageViewerUITestHost()
                } else {
                    RootView()
                }
#else
                RootView()
#endif
            }
            .environmentObject(environment)
            .environmentObject(appearanceStore)
            .environmentObject(readingPreferencesStore)
            .environment(\.readingPreferences, readingPreferencesStore.preferences)
            .preferredColorScheme(appearanceStore.selection.preferredColorScheme)
        }
    }
}

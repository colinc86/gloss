import OSLog
import SwiftUI

@main
struct GlossApp: App {
    private let launchOptions: AppLaunchOptions

    init() {
        let options = AppLaunchOptions(arguments: CommandLine.arguments)
        launchOptions = options
        Log.app.info("Launch options: \(String(describing: options), privacy: .public)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView(launchOptions: launchOptions)
        }
        .defaultSize(width: 1200, height: 800)

        Settings {
            SettingsPlaceholderView()
        }
    }
}

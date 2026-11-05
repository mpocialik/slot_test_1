import SwiftUI

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup("Foundation Model Tester") {
            ContentView()
                #if os(macOS)
                .frame(minWidth: 640, minHeight: 720)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 820, height: 900)
        .windowResizability(.contentMinSize)
        #endif
    }
}

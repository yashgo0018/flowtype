import AppKit
import SwiftData
import SwiftUI

@main
struct FlowtypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let modelContainer: ModelContainer

    init() {
        do {
            let schema = Schema(NativeSchema.models)
            let configuration = ModelConfiguration("Flowtype", schema: schema)
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup("Flow Hub") {
            HubRootView()
                .environmentObject(appDelegate.controller)
                .modelContainer(modelContainer)
                .onAppear {
                    let store = LocalStore(context: modelContainer.mainContext)
                    appDelegate.attachLocalStore(store)
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppStateController()
    private var flowBarController: FlowBarPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller.checkPermissions()
        let panelController = FlowBarPanelController(controller: controller)
        flowBarController = panelController
        panelController.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        flowBarController = nil
    }

    func attachLocalStore(_ store: LocalStore) {
        controller.attachLocalStore(store)
    }
}

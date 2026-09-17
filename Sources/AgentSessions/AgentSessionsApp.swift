import SwiftUI

@main
struct AgentSessionsApp: App {
    /// One store shared by the window and the menu bar item.
    @StateObject private var store = SessionStore()
    @StateObject private var tagStore = TagStore()
    @StateObject private var classificationStore = FindingClassificationStore()

    var body: some Scene {
        Window("Agent Sessions", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(tagStore)
                .environmentObject(classificationStore)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1040, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(store)
        } label: {
            MenuBarLabel(
                todayTokens: store.todayUsage.tokens,
                hasActive: !store.activeSessionIds.isEmpty
            )
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu bar label

/// App mark, a live dot while a session is running, and today's token spend.
private struct MenuBarLabel: View {
    let todayTokens: Int
    let hasActive: Bool

    var body: some View {
        HStack(spacing: 4) {
            StackMark()
                .frame(width: 14, height: 14)

            if hasActive {
                Circle()
                    .fill(Theme.result)
                    .frame(width: 5, height: 5)
            }

            if todayTokens > 0 {
                Text(TokenFormat.compact(todayTokens))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
            }
        }
    }
}

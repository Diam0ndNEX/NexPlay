import SwiftUI

// 8.6.0: Settings › Windows Games. With the Windows engine built in, the engine's own settings (Memory & performance,
// Graphics, Windows components, all engine options) through BCD's live backends (Windows/BCD/NexPlayBCDSettings.swift);
// without it, a note.
struct WindowsSettingsPage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                #if NEXPLAY_WINDOWS
                NexBCDSettingsView()
                #else
                NexMenuSection {
                    NexMenuNote(text: WindowsEngine.unavailableReason ?? "This build has no Windows engine, so there are no Windows settings.",
                                symbol: "info.circle.fill")
                }
                #endif
            }
            .padding(16)
            .padding(.bottom, 20)
        }
    }
}

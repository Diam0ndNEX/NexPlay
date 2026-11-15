import SwiftUI

// 8.6.3: Settings' sub-pages in the design system without rewriting every control. `NexForm` and `NexList` are a Form
// and a List whose rows sit on the colour profile's surface (the same card as NexMenuSection's rows), with profile-tinted
// hairlines, rounded type and the accent tint; the page background shows through (no stock grey). Toggles, pickers,
// sliders, navigation links and swipe actions keep working as in a plain Form/List. A Group around the content passes the
// row modifiers on to every section and row.

private struct NexFormRows: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowBackground(NexColor.surface.opacity(0.85))
            .listRowSeparatorTint(NexColor.stroke)
    }
}

/// A Form in NexPlay's design.
struct NexForm<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Form {
            Group { content() }
                .modifier(NexFormRows())
        }
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 48)
        .fontDesign(.rounded)
        .tint(NexColor.accent)
        .foregroundStyle(NexColor.text)
    }
}

/// A List (inset grouped) in NexPlay's design.
struct NexList<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        List {
            Group { content() }
                .modifier(NexFormRows())
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 48)
        .fontDesign(.rounded)
        .tint(NexColor.accent)
        .foregroundStyle(NexColor.text)
    }
}

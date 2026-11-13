import SwiftUI

// 7.13.0 (SPEC-7.0-review D6): every sheet gets the same header pieces: the title in the middle, a round close X
// on the right, and an optional ? that explains the sheet.

/// The round close button used by every sheet.
struct SheetCloseButton: View {
    let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}

/// The ? button: a short explanation of the sheet.
struct SheetHelpButton: View {
    let title: String
    let text: String
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "questionmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Help")
        .alert(title, isPresented: $showing) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(text)
        }
    }
}

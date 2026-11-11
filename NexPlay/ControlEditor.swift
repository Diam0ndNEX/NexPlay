import SwiftUI

// The Edit Button page and the Select Key page opened from the controls' edit mode. Layout follows RPGPlayer's
// screenshots (name, colour row, size, key mapping, delete; key tiles grouped by kind); NexPlay's own code.

/// What a control can be mapped to.
enum KeyChoice: Equatable {
    case action(ControlAction)
    case key(Int)

    init(_ item: ControlItem) {
        if item.action == .key, let code = item.keyCode {
            self = .key(code)
        } else {
            self = .action(item.action)
        }
    }

    var title: String {
        switch self {
        case .action(let action): return action.title
        case .key(let code): return PadKey.fromKeyCode(code).title
        }
    }
}

struct ControlEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var item: ControlItem
    @State private var name: String
    @State private var confirmDelete = false
    let onDone: (ControlItem?) -> Void
    private let original: ControlItem

    init(item: ControlItem, onDone: @escaping (ControlItem?) -> Void) {
        _item = State(initialValue: item)
        _name = State(initialValue: item.label ?? "")
        original = item
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                if item.action.isDirectional {
                    directionSection
                } else {
                    mappingSection
                }
                Section {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Text("Delete Button").font(.pixel(16))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground().ignoresSafeArea())
            .navigationTitle("Edit Button")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDone(original)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var result = item
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        result.label = trimmed.isEmpty ? nil : String(trimmed.prefix(10))
                        onDone(result)
                        dismiss()
                    }
                    .bold()
                }
            }
            .confirmationDialog("Delete this button?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    onDone(nil)
                    dismiss()
                }
            }
        }
        .font(.pixel(16))
        .environment(\.colorScheme, .dark)
        .interactiveDismissDisabled()
    }

    private var appearanceSection: some View {
        Section {
            if !item.action.isDirectional {
                TextField(item.displayLabel, text: $name)
                    .font(.pixel(18))
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Color")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        colorDot(nil)
                        ForEach(ControlColor.allCases) { tint in colorDot(tint) }
                    }
                    .padding(6)
                }
            }
            .padding(.vertical, 4)
            HStack {
                Text("Size")
                Slider(value: $item.size, in: 36...260, step: 1)
                Text("\(Int(item.size))").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            HStack {
                Text("Opacity")
                Slider(value: $item.opacity, in: 0.15...1)
                Text("\(Int(item.opacity * 100))%").monospacedDigit().frame(width: 52, alignment: .trailing)
            }
        } header: {
            Text("Button Appearance")
        }
    }

    private func colorDot(_ tint: ControlColor?) -> some View {
        let selected = item.color == tint?.rawValue
        return Button {
            item.color = tint?.rawValue
        } label: {
            ZStack {
                if let tint {
                    let rgb = tint.rgb
                    Circle().fill(Color(red: rgb.0, green: rgb.1, blue: rgb.2))
                } else {
                    Circle().fill(Color(white: 0.12))
                    Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1.5)
                }
                if selected {
                    Circle().strokeBorder(Color.white, lineWidth: 3).padding(-5)
                }
            }
            .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tint?.rawValue.capitalized ?? "Default")
    }

    private var mappingSection: some View {
        Section {
            NavigationLink {
                KeySelectView(selection: KeyChoice(item)) { choice in
                    switch choice {
                    case .action(let action):
                        item.action = action
                        item.keyCode = nil
                    case .key(let code):
                        item.action = .key
                        item.keyCode = code
                    }
                }
            } label: {
                LabeledContent("Key", value: KeyChoice(item).title)
            }
        } header: {
            Text("Key Mapping")
        }
    }

    private var directionSection: some View {
        Section {
            Picker("Type", selection: $item.action) {
                Text("Joystick").tag(ControlAction.joystick)
                Text("D-Pad").tag(ControlAction.dpad)
            }
            .pickerStyle(.segmented)
            Toggle("Eight Directions", isOn: Binding(
                get: { item.eightWay ?? true },
                set: { item.eightWay = $0 }
            ))
        } header: {
            Text("Directions")
        } footer: {
            Text("Presses the arrow keys. Turn off Eight Directions for games that only move in four.")
        }
    }
}

struct KeySelectView: View {
    @Environment(\.dismiss) private var dismiss
    @State var selection: KeyChoice
    let onPick: (KeyChoice) -> Void

    private let columns = [GridItem(.adaptive(minimum: 66, maximum: 140), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                group("Game Actions") {
                    VStack(spacing: 0) {
                        actionRow(.confirm, "checkmark.circle.fill")
                        actionRow(.cancel, "xmark.circle.fill")
                        actionRow(.menu, "line.3.horizontal")
                        actionRow(.dash, "hare.fill")
                        actionRow(.pageUp, "chevron.up.2")
                        actionRow(.pageDown, "chevron.down.2")
                        actionRow(.fastForward, "forward.fill")
                    }
                }
                group("Mouse Wheel", footer: "Sends a mouse wheel notch instead of a key. Hold the button to keep scrolling. Use this for games that scroll lists or menus with the wheel.") {
                    VStack(spacing: 0) {
                        actionRow(.scrollUp, "arrow.up.to.line")
                        actionRow(.scrollDown, "arrow.down.to.line")
                    }
                }
                keyGroup("Letters", PadKey.letters)
                keyGroup("Numbers", PadKey.digits)
                keyGroup("Arrows & Navigation", PadKey.navigation)
                keyGroup("Control Keys", PadKey.controlKeys)
                keyGroup("F-Keys", PadKey.functionKeys)
                keyGroup("Symbols", PadKey.symbols)
            }
            .padding(16)
        }
        .background(AppBackground().ignoresSafeArea())
        .navigationTitle("Select Key")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func group<Content: View>(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.pixel(14)).foregroundStyle(.secondary).padding(.leading, 4)
            content()
                .padding(10)
                .background(Color(white: 0.11).opacity(0.92), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            if let footer {
                Text(footer).font(.pixel(12)).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
    }

    private func keyGroup(_ title: String, _ keys: [PadKey]) -> some View {
        group(title) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(keys, id: \.keyCode) { key in
                    let chosen = selection == .key(key.keyCode)
                    Button {
                        pick(.key(key.keyCode))
                    } label: {
                        Text(key.shortTitle)
                            .font(.pixel(18))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(chosen ? NexStyle.accent : Color(white: 0.17),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
        }
    }

    private func actionRow(_ action: ControlAction, _ symbol: String) -> some View {
        let chosen = selection == .action(action)
        return Button {
            pick(.action(action))
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol).frame(width: 26)
                Text(action.title).font(.pixel(17))
                Spacer()
                if chosen { Image(systemName: "checkmark").foregroundStyle(NexStyle.accent) }
            }
            .foregroundStyle(.white)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pick(_ choice: KeyChoice) {
        selection = choice
        onPick(choice)
        UISelectionFeedbackGenerator().selectionChanged()
        dismiss()
    }
}

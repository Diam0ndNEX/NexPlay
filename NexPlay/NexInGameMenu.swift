import UIKit
import SwiftUI

// 8.3.0: NexPlay's in-game menu, in BCD's layout (BCDInGameMenu: a still panel over the dimmed game, docked to the
// leading edge in landscape and the bottom in portrait; eyebrow + title + close, page tabs, sections of rows in
// cards, pages that push in, questions asked inside the panel). NexPlay's own code on the 8.1 design system; the
// content (which sections, which rows) comes from the caller, so every engine can fill it (Game Panel for web-view
// games now, the Windows panel in 8.3.1). No BCD type is named here.

/// A page tab of the menu.
struct NexMenuTab: Identifiable, Hashable {
    let id: String
    let title: String
}

/// A question asked inside the panel (instead of an alert over the game).
struct NexMenuQuestion: Identifiable {
    let id = UUID()
    let title: String
    var message: String = ""
    let answer: String
    var destructive = false
    let action: () -> Void
}

/// Presents a menu over the game: full screen, transparent, the game's own orientation.
final class NexMenuHostingController<Content: View>: UIHostingController<Content> {
    override init(rootView: Content) {
        super.init(rootView: rootView)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        modalPresentationCapturesStatusBarAppearance = true
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        presentingViewController?.supportedInterfaceOrientations ?? .all
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}

// MARK: - The panel

struct NexInGameMenu<Content: View>: View {
    let eyebrow: String
    let title: String
    let symbol: String
    let tint: Color
    let tabs: [NexMenuTab]
    @Binding var tab: String
    let pageTitle: String?
    let back: (() -> Void)?
    @Binding var question: NexMenuQuestion?
    let status: String?
    let working: Bool
    let close: () -> Void
    let content: () -> Content

    @State private var shown = false
    @Namespace private var tabSpace
    @Environment(\.horizontalSizeClass) private var horizontal
    @Environment(\.verticalSizeClass) private var vertical
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(eyebrow: String, title: String, symbol: String, tint: Color, tabs: [NexMenuTab], tab: Binding<String>,
         pageTitle: String? = nil, back: (() -> Void)? = nil, question: Binding<NexMenuQuestion?>,
         status: String? = nil, working: Bool = false, close: @escaping () -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.eyebrow = eyebrow
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.tabs = tabs
        self._tab = tab
        self.pageTitle = pageTitle
        self.back = back
        self._question = question
        self.status = status
        self.working = working
        self.close = close
        self.content = content
    }

    private var pad: Bool { horizontal == .regular && vertical == .regular }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 24, style: .continuous) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .accessibilityLabel("Back to the game")
                .accessibilityAddTraits(.isButton)
            GeometryReader { geo in
                let wide = geo.size.width > geo.size.height
                let width = panelWidth(geo.size, wide: wide)
                let height = panelHeight(geo.size, wide: wide)
                panel
                    .frame(width: width, height: height)
                    .padding(.leading, wide ? 12 : 0)
                    .padding(.bottom, wide ? 0 : 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: wide ? .leading : .bottom)
                    .offset(x: shown || !wide || reduceMotion ? 0 : -(width + 40),
                            y: shown || wide || reduceMotion ? 0 : height + 40)
                    .opacity(shown || !reduceMotion ? 1 : 0)
            }
        }
        .foregroundStyle(NexColor.text)
        .environment(\.colorScheme, .dark)
        .onAppear {
            withAnimation(NexMotion.pick(NexMotion.smooth)) { shown = true }
        }
    }

    private func panelWidth(_ size: CGSize, wide: Bool) -> CGFloat {
        if wide { return min(pad ? 470 : 410, max(320, size.width * 0.5)) }
        return min(pad ? 600 : size.width - 16, size.width - 16)
    }

    private func panelHeight(_ size: CGSize, wide: Bool) -> CGFloat {
        if wide { return max(240, size.height - 16) }
        return min(size.height * (pad ? 0.7 : 0.82), size.height - 16)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)
            if question == nil && back == nil && tabs.count > 1 {
                tabBar.padding(.horizontal, 14).padding(.bottom, 10)
            }
            Rectangle().fill(NexColor.stroke.opacity(0.8)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let question {
                        confirmCard(question)
                    } else {
                        content()
                    }
                }
                .padding(14)
                .padding(.bottom, 44)
            }
            .scrollIndicators(.hidden)
        }
        .background(NexColor.panel.opacity(0.97), in: shape)
        .overlay(alignment: .top) {
            // The engine's light along the top edge.
            LinearGradient(colors: [tint.opacity(0.24), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 96)
                .allowsHitTesting(false)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(NexColor.stroke, lineWidth: 1))
        .overlay(alignment: .bottom) { statusCapsule }
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        .nexAnimation(NexMotion.snappy, value: status)
        .nexAnimation(NexMotion.snappy, value: pageTitle)
        .nexAnimation(NexMotion.snappy, value: question?.id)
    }

    // MARK: Header and tabs

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if let back, question == nil {
                Button {
                    NexHaptics.tap()
                    back()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(NexGlassIconButtonStyle(size: 36))
                .accessibilityLabel("Back")
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                NexMenuEyebrow(text: back == nil || question != nil ? eyebrow : title, tint: tint)
                Text(question != nil ? title : (pageTitle ?? title))
                    .font(NexType.title(pad ? 22 : 19))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if working { ProgressView().tint(NexColor.text) }
            Button {
                NexHaptics.tap()
                close()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(NexGlassIconButtonStyle(size: 36))
            .accessibilityLabel("Back to the game")
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(tabs) { item in
                let selected = item.id == tab
                Button {
                    guard !selected else { return }
                    NexHaptics.selection()
                    NexMotion.run(NexMotion.snappy) { tab = item.id }
                } label: {
                    Text(item.title)
                        .font(NexType.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(selected ? NexColor.onAccent : NexColor.textSoft)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background {
                            if selected {
                                Capsule().fill(NexColor.accent).matchedGeometryEffect(id: "tab", in: tabSpace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .nexGlassCapsule()
    }

    @ViewBuilder private var statusCapsule: some View {
        if let status {
            Text(status)
                .font(NexType.label)
                .foregroundStyle(NexColor.text)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .nexGlassCapsule()
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }

    // MARK: A question

    private func confirmCard(_ ask: NexMenuQuestion) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(ask.title).font(NexType.title(19)).fixedSize(horizontal: false, vertical: true)
            if !ask.message.isEmpty {
                Text(ask.message).font(NexType.body).foregroundStyle(NexColor.textSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if ask.destructive {
                Button {
                    NexHaptics.warning()
                    question = nil
                    ask.action()
                } label: {
                    Text(ask.answer)
                        .font(NexType.label)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(NexColor.danger.opacity(0.9), in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    NexHaptics.press()
                    question = nil
                    ask.action()
                } label: {
                    Text(ask.answer)
                }
                .buttonStyle(NexPrimaryButtonStyle())
            }
            Button("Cancel") { question = nil }
                .buttonStyle(NexGlassButtonStyle())
        }
        .padding(16)
        .background(NexColor.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(NexColor.stroke, lineWidth: 1))
        .transition(.opacity)
    }
}

// MARK: - Sections and rows

/// A small caps label over a section or a title.
struct NexMenuEyebrow: View {
    let text: String
    var tint: Color = NexColor.textSoft

    var body: some View {
        Text(text.uppercased())
            .font(.system(.caption2, design: .rounded).weight(.bold))
            .tracking(0.7)
            .foregroundStyle(tint)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A titled card of rows with hairlines between them (BCD's section).
struct NexMenuSection<Content: View>: View {
    let title: String?
    let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title { NexMenuEyebrow(text: title).padding(.leading, 4) }
            Group(subviews: content) { rows in
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Rectangle().fill(NexColor.stroke.opacity(0.7)).frame(height: 1).padding(.leading, 14)
                        }
                        row
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NexColor.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: NexMetrics.cornerM, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: NexMetrics.cornerM, style: .continuous).strokeBorder(NexColor.stroke, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: NexMetrics.cornerM, style: .continuous))
            }
        }
    }
}

/// Symbol, title and detail on the left of a row.
private struct NexMenuTitles: View {
    let title: String
    let detail: String?
    let symbol: String?
    var tint: Color = NexColor.text

    var body: some View {
        HStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint == NexColor.text ? NexColor.accentSoft : tint)
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(NexType.label).foregroundStyle(tint).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(NexType.caption).foregroundStyle(NexColor.textSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A row that is one button.
struct NexMenuRow: View {
    enum Accessory { case none, chevron, value(String), check(Bool) }

    let title: String
    var detail: String? = nil
    var symbol: String? = nil
    var accessory: Accessory = .none
    var destructive = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button {
            NexHaptics.tap()
            action()
        } label: {
            HStack(spacing: 12) {
                NexMenuTitles(title: title, detail: detail, symbol: symbol, tint: destructive ? NexColor.danger : NexColor.text)
                Spacer(minLength: 8)
                switch accessory {
                case .none:
                    EmptyView()
                case .chevron:
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(NexColor.textSoft)
                case .value(let text):
                    HStack(spacing: 6) {
                        Text(text).font(NexType.caption).foregroundStyle(NexColor.textSoft).lineLimit(1)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(NexColor.textSoft)
                    }
                case .check(let on):
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(on ? NexColor.accent : NexColor.textSoft.opacity(0.6))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(NexMenuRowPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// A row with an on/off switch; the whole row is the button.
struct NexMenuToggleRow: View {
    let title: String
    var detail: String? = nil
    var symbol: String? = nil
    let isOn: Bool
    var enabled = true
    let set: (Bool) -> Void

    var body: some View {
        Button {
            NexHaptics.selection()
            NexMotion.run(NexMotion.snappy) { set(!isOn) }
        } label: {
            HStack(spacing: 12) {
                NexMenuTitles(title: title, detail: detail, symbol: symbol)
                Spacer(minLength: 8)
                NexMenuSwitch(on: isOn)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(NexMenuRowPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// One choice of a chips row.
struct NexMenuChoice<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
}

/// A title over wrapping chips; `selected` nil = buttons with no selection (actions).
struct NexMenuChipsRow<Value: Hashable>: View {
    let title: String
    var detail: String? = nil
    var symbol: String? = nil
    let choices: [NexMenuChoice<Value>]
    let selected: Value?
    var enabled = true
    let choose: (Value) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            NexMenuTitles(title: title, detail: detail, symbol: symbol)
            NexChipFlow(spacing: 7) {
                ForEach(choices) { choice in
                    let on = selected == choice.value
                    Button {
                        NexHaptics.selection()
                        NexMotion.run(NexMotion.snappy) { choose(choice.value) }
                    } label: {
                        Text(choice.title)
                            .font(NexType.label)
                            .lineLimit(1)
                            .foregroundStyle(on ? NexColor.onAccent : NexColor.text)
                            .padding(.horizontal, 13)
                            .frame(minHeight: 34)
                            .background {
                                if on { Capsule().fill(NexColor.accent) } else { Capsule().fill(NexColor.surfaceRaised) }
                            }
                            .overlay(Capsule().strokeBorder(NexColor.stroke, lineWidth: on ? 0 : 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(NexMenuRowPressStyle())
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// A title, a value and a bar to drag.
struct NexMenuSliderRow: View {
    let title: String
    var symbol: String? = nil
    let value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    let text: String
    let change: (Double) -> Void
    var commit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                NexMenuTitles(title: title, detail: nil, symbol: symbol)
                Spacer(minLength: 8)
                Text(verbatim: text).font(NexType.number).foregroundStyle(NexColor.accentSoft)
            }
            NexValueBar(value: value, range: range, step: step, set: change, done: commit)
                .frame(height: 28)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(text)
        .accessibilityAdjustableAction { direction in
            let size = step > 0 ? step : (range.upperBound - range.lowerBound) / 10
            let next = min(range.upperBound, max(range.lowerBound, value + (direction == .increment ? size : -size)))
            change(next)
            commit()
        }
    }
}

/// A line of help text inside a section.
struct NexMenuNote: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = NexColor.textSoft

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
            Text(text).font(NexType.caption).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// Any view as a padded row.
struct NexMenuCustomRow<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Small controls

private struct NexMenuRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.06 : 0))
            .animation(NexMotion.press, value: configuration.isPressed)
    }
}

/// An on/off switch in the accent colour.
struct NexMenuSwitch: View {
    let on: Bool

    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule()
                .fill(on ? NexColor.accent : NexColor.surfaceRaised)
                .overlay(Capsule().strokeBorder(NexColor.stroke, lineWidth: on ? 0 : 1))
            Circle().fill(Color.white).frame(width: 22, height: 22).padding(3)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        }
        .frame(width: 50, height: 28)
        .nexAnimation(NexMotion.snappy, value: on)
        .accessibilityHidden(true)
    }
}

/// A value along a bar: drag or tap to set it; snaps to `step` (0 = no snapping).
struct NexValueBar: View {
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let set: (Double) -> Void
    var done: () -> Void = {}

    var body: some View {
        GeometryReader { proxy in
            let span = max(0.0001, range.upperBound - range.lowerBound)
            let fraction = min(1, max(0, (value - range.lowerBound) / span))
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(NexColor.surfaceRaised).frame(height: 6)
                Capsule().fill(NexColor.accentGradient).frame(width: max(6, width * fraction), height: 6)
                Circle().fill(Color.white).frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(x: max(0, min(width - 22, width * fraction - 11)))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let share = min(1, max(0, drag.location.x / max(1, width)))
                    var next = range.lowerBound + share * span
                    if step > 0 { next = (next / step).rounded() * step }
                    next = min(range.upperBound, max(range.lowerBound, next))
                    if abs(next - value) > max(step / 4, 0.001) { set(next) }
                }
                .onEnded { _ in done() })
        }
    }
}

/// Chips in rows, wrapping when a row is full.
struct NexChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

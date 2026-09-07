import AppKit
import SwiftUI

/// Bridges the canvas (selection + current tool style) to the floating
/// Shottr-style properties capsule. Hosts call `refresh()` whenever the tool or
/// selection changes; edits flow back into the canvas as undoable updates.
@MainActor
final class PropertiesPanelModel: ObservableObject {
    @Published var kind: AnnotationKind? = nil
    @Published var style = ToolStyle()
    @Published var selected: Annotation? = nil
    @Published var collapsed = false

    weak var canvas: AnnotationCanvasView?
    /// Called after the tool style changed so the host can persist it.
    var onStyleChanged: ((ToolStyle) -> Void)?

    func refresh() {
        guard let canvas else { return }
        style = canvas.style
        selected = canvas.selectedAnnotation
        kind = selected?.kind ?? canvas.tool.annotationKind
    }

    /// Whether the capsule has anything to show.
    var isVisible: Bool { kind != nil }

    // Current values (selection wins over the tool style)
    var color: AnnotationColor {
        get { selected?.color ?? (kind == .highlighter ? style.highlighterColor : style.color) }
        set { apply { $0.color = newValue } style: { if self.kind == .highlighter { $0.highlighterColor = newValue } else { $0.color = newValue } } }
    }
    var thickness: CGFloat {
        get { selected?.thickness ?? (kind == .highlighter ? style.highlighterThickness : style.thickness) }
        set { apply { $0.thickness = newValue } style: { if self.kind == .highlighter { $0.highlighterThickness = newValue } else { $0.thickness = newValue } } }
    }
    var arrowType: ArrowType {
        get { selected?.arrowType ?? style.arrowType }
        set { apply { $0.arrowType = newValue } style: { $0.arrowType = newValue } }
    }
    var shapeStyle: ShapeStyle {
        get { selected?.shapeStyle ?? style.shapeStyle }
        set { apply { $0.shapeStyle = newValue } style: { $0.shapeStyle = newValue } }
    }
    var blurMode: BlurMode {
        get { selected?.blurMode ?? style.blurMode }
        set { apply { $0.blurMode = newValue } style: { $0.blurMode = newValue } }
    }
    var blurStrength: CGFloat {
        get { selected?.blurStrength ?? style.blurStrength }
        set { apply { $0.blurStrength = newValue } style: { $0.blurStrength = newValue } }
    }
    var textStyle: TextStyle {
        get { selected?.textStyle ?? style.textStyle }
        set { apply { $0.textStyle = newValue } style: { $0.textStyle = newValue } }
    }
    var textPointer: Bool {
        get { selected?.textPointer ?? style.textPointer }
        set {
            apply {
                $0.textPointer = newValue
                if newValue, $0.pointerTip == nil { $0.pointerTip = AnnotationRenderer.defaultPointerTip(forBubble: $0.rect) }
            } style: { $0.textPointer = newValue }
        }
    }
    var fontSize: CGFloat {
        get { selected?.fontSize ?? style.fontSize }
        set { apply { $0.fontSize = newValue } style: { $0.fontSize = newValue } }
    }
    var size: SizeStep {
        get { selected?.size ?? style.size }
        set { apply { $0.size = newValue } style: { $0.size = newValue } }
    }

    func flipArrow() {
        apply { swap(&$0.start, &$0.end) } style: { _ in }
    }

    private func apply(_ mutate: @escaping (inout Annotation) -> Void, style mutateStyle: (inout ToolStyle) -> Void) {
        guard let canvas else { return }
        if selected != nil {
            canvas.updateSelected(mutate)
        }
        mutateStyle(&canvas.style)
        style = canvas.style
        selected = canvas.selectedAnnotation
        onStyleChanged?(canvas.style)
    }
}

struct PropertiesPanelView: View {
    @ObservedObject var model: PropertiesPanelModel

    var body: some View {
        HStack(spacing: 10) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { model.collapsed.toggle() } } label: {
                Image(systemName: model.collapsed ? "chevron.right" : "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 20)
            }
            .buttonStyle(.plain)
            .help(model.collapsed ? "Show options" : "Hide options")

            if !model.collapsed, let kind = model.kind {
                content(for: kind)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        .fixedSize()
    }

    @ViewBuilder
    private func content(for kind: AnnotationKind) -> some View {
        switch kind {
        case .arrow:
            colorSwatch; thicknessSlider
            Divider().frame(height: 18)
            segmented(ArrowType.allCases, selection: Binding(get: { model.arrowType }, set: { model.arrowType = $0 })) { t in
                Image(systemName: t == .tapered ? "arrow.right" : "arrow.right.to.line").imageScale(.medium)
            }
            Button { model.flipArrow() } label: { Image(systemName: "arrow.left.arrow.right") }
                .buttonStyle(.borderless).help("Flip direction (⌘-click arrow)")
                .disabled(model.selected == nil)
        case .line, .freehand, .highlighter:
            colorSwatch; thicknessSlider
        case .rectangle, .oval:
            colorSwatch; thicknessSlider
            Divider().frame(height: 18)
            segmented(ShapeStyle.allCases, selection: Binding(get: { model.shapeStyle }, set: { model.shapeStyle = $0 })) { s in
                switch s {
                case .outline: Image(systemName: kind == .oval ? "circle" : "square")
                case .translucent: Image(systemName: kind == .oval ? "circle.lefthalf.filled" : "square.lefthalf.filled")
                case .solid: Image(systemName: kind == .oval ? "circle.fill" : "square.fill")
                }
            }
        case .blur:
            Slider(value: Binding(get: { model.blurStrength }, set: { model.blurStrength = $0 }), in: 0...1)
                .frame(width: 110).controlSize(.small).help("Strength")
            Divider().frame(height: 18)
            segmented(BlurMode.allCases, selection: Binding(get: { model.blurMode }, set: { model.blurMode = $0 }), width: 58) { m in
                Text(m == .mosaic ? "Mosaic" : "Blur").font(.system(size: 12))
            }
        case .text:
            colorSwatch
            Slider(value: Binding(get: { model.fontSize }, set: { model.fontSize = $0.rounded() }), in: 10...72, step: 1)
                .frame(width: 110).controlSize(.small).help("Text size")
            Divider().frame(height: 18)
            segmented(TextStyle.allCases, selection: Binding(get: { model.textStyle }, set: { model.textStyle = $0 })) { s in
                Image(systemName: s == .label ? "t.square.fill" : "textformat")
            }
            Toggle(isOn: Binding(get: { model.textPointer }, set: { model.textPointer = $0 })) {
                Image(systemName: "arrow.down.left")
            }
            .toggleStyle(.button).buttonStyle(.borderless).help("Pointer tail")
            .disabled(model.textStyle != .label)
        case .counter:
            colorSwatch; sizeSlider
        }
    }

    private var colorSwatch: some View { ColorSwatchButton(color: Binding(get: { model.color }, set: { model.color = $0 })) }

    private var thicknessSlider: some View {
        Slider(value: Binding(get: { model.thickness }, set: { model.thickness = $0 }), in: 1...(model.kind == .highlighter ? 40 : 20))
            .frame(width: 110).controlSize(.small).help("Thickness")
    }

    private var sizeSlider: some View {
        Slider(value: Binding(get: { Double(model.size.rawValue) }, set: { model.size = SizeStep(rawValue: Int($0.rounded())) ?? .m }),
               in: 1...5, step: 1)
            .frame(width: 110).controlSize(.small).help("Size")
    }

    private func segmented<T: Hashable, L: View>(_ items: [T], selection: Binding<T>, width: CGFloat = 24, @ViewBuilder label: @escaping (T) -> L) -> some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                Button { selection.wrappedValue = item } label: {
                    label(item)
                        .frame(width: width, height: 20)
                        .background(selection.wrappedValue == item ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(selection.wrappedValue == item ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Rounded color swatch that opens a palette popover with a custom color picker.
struct ColorSwatchButton: View {
    @Binding var color: AnnotationColor
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: color.nsColor))
                .frame(width: 22, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.black.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .help("Color")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 6), count: 5), spacing: 6) {
                    ForEach(AnnotationColor.palette, id: \.self) { c in
                        Button { color = c; showing = false } label: {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: c.nsColor))
                                .frame(width: 26, height: 26)
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(c == color ? Color.accentColor : Color.black.opacity(0.15), lineWidth: c == color ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                ColorPicker("Custom", selection: Binding(get: { Color(nsColor: color.nsColor) },
                                                          set: { color = AnnotationColor(NSColor($0)) }), supportsOpacity: false)
                    .font(.system(size: 12))
            }
            .padding(10)
        }
    }
}

/// AppKit host for the capsule so overlay panels and the editor window can place it.
@MainActor
final class PropertiesPanelHost {
    let model: PropertiesPanelModel
    let view: NSHostingView<PropertiesPanelView>

    init(model: PropertiesPanelModel) {
        self.model = model
        view = NSHostingView(rootView: PropertiesPanelView(model: model))
        view.translatesAutoresizingMaskIntoConstraints = false
    }

    var fittingSize: CGSize { view.fittingSize }
}

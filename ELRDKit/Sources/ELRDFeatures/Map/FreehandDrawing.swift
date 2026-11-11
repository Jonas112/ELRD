import SwiftUI
import PencilKit
import MapKit
import ELRDDomain

/// Stift für das Freihandzeichnen: Farbe, Strichstärke oder Radierer.
struct FreehandTool: Equatable {
    var color: RGBColor = MapObject.defaultColor
    var width: CGFloat = 6
    var isErasing = false

    static let widths: [(title: String, width: CGFloat)] = [("Dünn", 3), ("Mittel", 6), ("Dick", 12)]
}

/// Verbindung zur Zeichenfläche: Rückgängig, Anzahl Striche, Bild erzeugen.
///
/// Die Zeichnung hängt an der Karte, als wäre sie schon gespeichert (Jonas): Beim
/// Start merkt sich der Controller, welche Orte die Ecken der Fläche zeigen. Die
/// Striche liegen in diesem Ausgangsmaßstab (`base`); bei jedem Verschieben oder
/// Zoomen wird die Zeichnung in den aktuellen Kartenausschnitt umgerechnet. Die
/// Fläche selbst bleibt bildschirmfüllend – gezeichnet wird in jedem Maßstab.
/// Ein Finger oder der Stift zeichnet, zwei Finger verschieben und zoomen.
@MainActor
final class FreehandController: ObservableObject {
    weak var canvas: PKCanvasView?
    /// Karte für das Verschieben und Zoomen mit zwei Fingern.
    var proxy: MapCanvasProxy?
    @Published private(set) var strokeCount = 0
    /// Orte der linken oberen und rechten unteren Ecke beim Start, Größe der Fläche.
    private var anchor: (topLeft: GeoCoordinate, bottomRight: GeoCoordinate, size: CGSize)?
    /// Striche im Ausgangsmaßstab (Koordinaten der Fläche beim Start).
    private var base = PKDrawing()
    /// Aktuelle Umrechnung Ausgangsmaßstab → Bildschirm.
    private var current = CGAffineTransform.identity
    /// Zeichnung wird gerade programmatisch gesetzt (kein Benutzerstrich).
    private var isApplying = false

    /// Ecken der Fläche an der Karte festmachen (einmal, sobald sie ihre Größe hat).
    func anchorIfNeeded(_ proxy: MapCanvasProxy) {
        self.proxy = proxy
        guard anchor == nil, let canvas, canvas.bounds.width > 1, canvas.bounds.height > 1,
              let topLeft = proxy.coordinate(at: .zero),
              let bottomRight = proxy.coordinate(at: CGPoint(x: canvas.bounds.width, y: canvas.bounds.height)) else { return }
        anchor = (topLeft, bottomRight, canvas.bounds.size)
        current = .identity
    }

    /// Zeichnung dem Kartenausschnitt folgen lassen (bei jeder Änderung des Ausschnitts).
    func followMap(_ proxy: MapCanvasProxy) {
        anchorIfNeeded(proxy)
        guard let transform = mapping(proxy), transform != current else { return }
        current = transform
        apply()
    }

    /// Ausgangsmaßstab → Bildschirm: Punkt p → Ecke + Zoom · p (Norden bleibt oben).
    private func mapping(_ proxy: MapCanvasProxy) -> CGAffineTransform? {
        guard let anchor,
              let origin = proxy.point(for: anchor.topLeft),
              let corner = proxy.point(for: anchor.bottomRight) else { return nil }
        let scale = (corner.x - origin.x) / anchor.size.width
        guard scale.isFinite, scale > 0.001 else { return nil }
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: origin.x, ty: origin.y)
    }

    private func apply() {
        guard let canvas else { return }
        isApplying = true
        canvas.drawing = base.transformed(using: current)
        isApplying = false
        strokeCount = base.strokes.count
    }

    func reset() {
        anchor = nil
        base = PKDrawing()
        current = .identity
        isApplying = true
        canvas?.drawing = PKDrawing()
        isApplying = false
        strokeCount = 0
    }

    /// Benutzer hat gezeichnet oder radiert: in den Ausgangsmaßstab übernehmen.
    func drawingChanged() {
        guard !isApplying, let canvas else { return }
        base = canvas.drawing.transformed(using: current.inverted())
        strokeCount = base.strokes.count
    }

    /// Letzten Strich entfernen (unabhängig vom Undo-Manager der Ansicht).
    func undo() {
        guard !base.strokes.isEmpty else { return }
        base.strokes.removeLast()
        apply()
    }

    func clear() {
        base = PKDrawing()
        apply()
    }

    /// Zeichnung als transparentes PNG mit den Orten ihrer Ecken – auch Teile
    /// außerhalb des aktuellen Ausschnitts.
    func export(_ proxy: MapCanvasProxy) -> (png: Data, topLeft: GeoCoordinate, bottomRight: GeoCoordinate, pixelSize: CGSize)? {
        guard !base.strokes.isEmpty else { return nil }
        let zoom = max(current.a, 0.001)
        // Rand ~6 pt auf dem Bildschirm, im Ausgangsmaßstab umgerechnet.
        let rect = base.bounds.insetBy(dx: -6 / zoom, dy: -6 / zoom)
        guard !rect.isNull, rect.width > 0.5, rect.height > 0.5 else { return nil }
        // Auflösung wie auf dem Bildschirm (Retina), höchstens 4096 px Kantenlänge.
        var scale = 2 * zoom
        scale = min(scale, 4096 / max(rect.width, rect.height))
        scale = max(scale, 0.5)
        let image = base.image(from: rect, scale: scale)
        guard let png = image.pngData() else { return nil }
        let topLeftScreen = CGPoint(x: rect.minX, y: rect.minY).applying(current)
        let bottomRightScreen = CGPoint(x: rect.maxX, y: rect.maxY).applying(current)
        guard let topLeft = proxy.coordinate(at: topLeftScreen),
              let bottomRight = proxy.coordinate(at: bottomRightScreen) else { return nil }
        return (png, topLeft, bottomRight, CGSize(width: rect.width * scale, height: rect.height * scale))
    }
}

/// Durchsichtige PencilKit-Fläche über der Karte. Ein Finger oder Stift zeichnet,
/// zwei Finger verschieben und zoomen die Karte (die Zeichnung folgt).
struct FreehandCanvas: UIViewRepresentable {
    let controller: FreehandController
    let tool: FreehandTool

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.delegate = context.coordinator
        controller.canvas = canvas
        apply(tool, to: canvas)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.delegate = context.coordinator
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        pinch.delegate = context.coordinator
        canvas.addGestureRecognizer(pan)
        canvas.addGestureRecognizer(pinch)
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        apply(tool, to: canvas)
    }

    private func apply(_ tool: FreehandTool, to canvas: PKCanvasView) {
        if tool.isErasing {
            canvas.tool = PKEraserTool(.vector)
        } else {
            canvas.tool = PKInkingTool(.pen, color: UIColor(tool.color), width: tool.width)
        }
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
        let controller: FreehandController

        init(controller: FreehandController) {
            self.controller = controller
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            controller.drawingChanged()
        }

        /// Zweiter Finger: angefangenen Strich verwerfen, die Karte bewegt sich.
        private func cancelStroke() {
            guard let canvas = controller.canvas else { return }
            canvas.drawingGestureRecognizer.isEnabled = false
            canvas.drawingGestureRecognizer.isEnabled = true
        }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began { cancelStroke() }
            guard recognizer.state == .changed, let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            controller.proxy?.pan(by: translation)
            recognizer.setTranslation(.zero, in: view)
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            if recognizer.state == .began { cancelStroke() }
            guard recognizer.state == .changed, let view = recognizer.view else { return }
            controller.proxy?.zoom(by: recognizer.scale, around: recognizer.location(in: view))
            recognizer.scale = 1
        }

        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

// MARK: - Darstellung auf der Karte

/// Zeichnung als Kartenfläche: das Bild über seinem geografischen Rechteck.
final class DrawingOverlay: NSObject, MKOverlay {
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect
    let image: CGImage?

    init(bounds: GeoBounds, image: CGImage?) {
        let topLeft = MKMapPoint(CLLocationCoordinate2D(latitude: bounds.north, longitude: bounds.west))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(latitude: bounds.south, longitude: bounds.east))
        boundingMapRect = MKMapRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
        coordinate = bounds.center.clLocation
        self.image = image
        super.init()
    }
}

/// Zeichnet das Bild in sein Rechteck (MapKit ruft das auch abseits des Hauptthreads auf).
final class DrawingOverlayRenderer: MKOverlayRenderer {
    private let image: CGImage?
    private let imageRect: MKMapRect

    init(drawing: DrawingOverlay) {
        image = drawing.image
        imageRect = drawing.boundingMapRect
        super.init(overlay: drawing)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let image else { return }
        // Das Rechteck ist die Fläche selbst; im Renderer-Raum beginnt es bei 0/0
        // (so spart man `rect(for:)`, das je nach SDK an den Hauptthread gebunden ist).
        let size = CGSize(width: imageRect.size.width, height: imageRect.size.height)
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        context.restoreGState()
    }
}

/// Werkzeugleiste unten beim Freihandzeichnen: Farben, Strichstärke, Radierer,
/// Rückgängig, Abbrechen, Fertig. Große Ziele, auch mit Handschuhen.
struct FreehandToolbar: View {
    @Binding var tool: FreehandTool
    let strokeCount: Int
    let onUndo: () -> Void
    let onCancel: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: Spacing.s) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.s) {
                    ForEach(MapObjectPalette.colors.indices, id: \.self) { index in
                        let entry = MapObjectPalette.colors[index]
                        Button {
                            tool.color = entry.color
                            tool.isErasing = false
                        } label: {
                            Circle()
                                .fill(Color(entry.color))
                                .frame(width: 36, height: 36)
                                .overlay {
                                    if !tool.isErasing, tool.color == entry.color {
                                        Circle().strokeBorder(Color.primary, lineWidth: 3).frame(width: 46, height: 46)
                                    }
                                }
                                .frame(width: TouchTarget.minimum + 4, height: TouchTarget.minimum + 4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(entry.name)
                        .accessibilityAddTraits(!tool.isErasing && tool.color == entry.color ? .isSelected : [])
                    }
                    Divider().frame(height: 36)
                    ForEach(FreehandTool.widths.indices, id: \.self) { index in
                        let entry = FreehandTool.widths[index]
                        ChoiceChip(entry.title, isSelected: !tool.isErasing && tool.width == entry.width, minHeight: TouchTarget.minimum + 4) {
                            tool.width = entry.width
                            tool.isErasing = false
                        }
                    }
                    ChoiceChip("Radierer", isSelected: tool.isErasing, minHeight: TouchTarget.minimum + 4) {
                        tool.isErasing.toggle()
                    }
                }
                .padding(.horizontal, Spacing.xs)
            }
            HStack(spacing: Spacing.s) {
                Button(action: onCancel) {
                    Text("Abbrechen").font(.headline)
                        .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable)
                        .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                }
                .buttonStyle(.plain)
                Button(action: onUndo) {
                    Label("Zurück", systemImage: "arrow.uturn.backward").font(.headline)
                        .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable)
                        .background(Surface.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(strokeCount == 0)
                Button(action: onDone) {
                    Label("Fertig", systemImage: "checkmark").font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: TouchTarget.comfortable)
                        .background(strokeCount == 0 ? Color.secondary : ActionFill.primary,
                                    in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(strokeCount == 0)
            }
        }
        .padding(Spacing.m)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        .padding(.horizontal, Spacing.l)
        .padding(.bottom, 36)
        .frame(maxWidth: 680)
    }
}

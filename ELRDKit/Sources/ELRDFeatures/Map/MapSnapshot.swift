import UIKit
import MapKit

extension MapCanvasProxy {
    /// Bild des sichtbaren Kartenausschnitts mit Grundlage, Flächen, Markierungen
    /// und Maßstab (wie ELRDRG `drawHierarchy`). Knöpfe liegen außerhalb der Karte
    /// und erscheinen daher nicht.
    func snapshot() -> UIImage? {
        guard let map, map.bounds.width > 1, map.bounds.height > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: map.bounds, format: format)
        return renderer.image { _ in
            map.drawHierarchy(in: map.bounds, afterScreenUpdates: true)
        }
    }
}

/// Drucken über das System (AirPrint). Auf dem iPad erscheint der Druckdialog
/// als eigenes Fenster.
@MainActor
enum MapPrinting {
    static func print(_ image: UIImage, jobName: String) {
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = jobName
        info.outputType = .photo
        info.orientation = image.size.width > image.size.height ? .landscape : .portrait
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = image
        controller.present(animated: true)
    }
}

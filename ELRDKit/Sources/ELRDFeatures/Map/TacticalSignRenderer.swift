import UIKit
import ELRDDomain

/// Zeichnet taktische Zeichen (Schritt 114) mit Core Graphics – für die Karte,
/// die Auswahl und das Lagebild. Geometrie nach DV 102 im Raster der
/// Vorlagen (Rahmen 75 × 45 Einheiten); Formen als Vorschlag von Claude,
/// fachlich von Jonas zu prüfen (E115).
///
/// Koordinaten der Grundzeichen angelehnt an „taktische-zeichen“ von Philipp
/// Jardas (github.com/phjardas/taktische-zeichen), MIT-Lizenz:
/// Copyright 2022-2026 Philipp Jardas. Permission is hereby granted, free of charge,
/// to any person obtaining a copy of this software and associated documentation files
/// (the "Software"), to deal in the Software without restriction, including without
/// limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
/// and/or sell copies of the Software, subject to the following conditions: The above
/// copyright notice and this permission notice shall be included in all copies or
/// substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT
/// WARRANTY OF ANY KIND.
enum TacticalSignRenderer {
    private static let hazardRed = UIColor(red: 0xFA / 255, green: 0x32 / 255, blue: 0x1E / 255, alpha: 1)
    private static let measureBlue = UIColor(red: 0x32 / 255, green: 0x64 / 255, blue: 0xFA / 255, alpha: 1)
    private static let lineWidth: CGFloat = 2

    /// Bild in der gewünschten Höhe (Punkte), mit durchsichtigem Rand.
    static func image(for sign: TacticalSign, height: CGFloat = 40) -> UIImage {
        let units = unitSize(of: sign)
        let scale = height / units.height
        let size = CGSize(width: ceil(units.width * scale) + 2, height: ceil(units.height * scale) + 2)
        return UIGraphicsImageRenderer(size: size).image { context in
            draw(sign, in: context.cgContext, origin: CGPoint(x: 1, y: 1), scale: scale)
        }
    }

    /// Größe in Rastereinheiten inklusive Stärke-Zeichen oben und Text unten.
    static func unitSize(of sign: TacticalSign) -> CGSize {
        let base = baseSize(sign.base)
        let top: CGFloat = sign.unitSize == nil ? 0 : 12
        let caption: CGFloat = hasCaption(sign) ? 16 : 0
        return CGSize(width: max(base.width, hasCaption(sign) ? 60 : 0), height: base.height + top + caption)
    }

    /// Zeichnet das Zeichen ab `origin` (linke obere Ecke) im Maßstab `scale` (Punkte je Einheit).
    static func draw(_ sign: TacticalSign, in context: CGContext, origin: CGPoint, scale: CGFloat) {
        let base = baseSize(sign.base)
        let total = unitSize(of: sign)
        let top: CGFloat = sign.unitSize == nil ? 0 : 12
        context.saveGState()
        context.translateBy(x: origin.x + (total.width - base.width) / 2 * scale, y: origin.y + top * scale)
        context.scaleBy(x: scale, y: scale)
        context.setLineWidth(lineWidth)
        context.setLineJoin(.round)
        context.setLineCap(.round)

        let fill = UIColor(sign.organisation.fill)
        let ink: UIColor = sign.organisation.usesWhiteInk ? .white : .black
        switch sign.base {
        case .gefahr, .gefahrAkut, .massnahme:
            drawHazardOrMeasure(sign, in: context)
        case .person, .personVerletzt, .personTot, .personZuTransportieren:
            drawPerson(sign, fill: fill, in: context)
        case .hubschrauber:
            drawHelicopter(fill: fill, in: context)
        default:
            let body = bodyPath(sign.base)
            context.addPath(body)
            context.setFillColor(fill.cgColor)
            context.fillPath()
            if let task = sign.task {
                context.saveGState()
                context.addPath(body)
                context.clip()
                drawTask(task, in: taskFrame(sign.base), color: ink, context: context)
                context.restoreGState()
            }
            context.setStrokeColor(UIColor.black.cgColor)
            context.addPath(outlinePath(sign.base))
            context.strokePath()
            if sign.base == .kraftfahrzeug {
                for x in [10.0, 65.0] {
                    context.addEllipse(in: CGRect(x: x - 5, y: 44, width: 10, height: 10))
                }
                context.setFillColor(UIColor.white.cgColor)
                context.drawPath(using: .fillStroke)
            }
            if !sign.text.isEmpty {
                drawText(sign.text, in: textFrame(sign), color: ink, context: context)
            }
        }
        context.restoreGState()

        if let unitSize = sign.unitSize {
            drawUnitSize(unitSize, centerX: origin.x + total.width / 2 * scale, top: origin.y, scale: scale, in: context)
        }
        if hasCaption(sign) {
            let captionTop = origin.y + (top + base.height + 2) * scale
            let frame = CGRect(x: origin.x, y: captionTop, width: total.width * scale, height: 14 * scale)
            drawCaption(sign.text, in: frame, scale: scale, context: context)
        }
    }

    // MARK: Grundzeichen

    private static func baseSize(_ base: TacticalBase) -> CGSize {
        switch base {
        case .taktischeFormation, .fahrzeug, .gebaeude: CGSize(width: 75, height: 45)
        case .befehlsstelle, .kraftfahrzeug: CGSize(width: 75, height: 55)
        case .stelle, .person, .personVerletzt, .personTot: CGSize(width: 45, height: 45)
        case .personZuTransportieren: CGSize(width: 45, height: 48)
        case .gefahr, .massnahme: CGSize(width: 45, height: 36)
        case .gefahrAkut: CGSize(width: 51.5, height: 36)
        case .hubschrauber: CGSize(width: 61, height: 37)
        }
    }

    /// Ohne Platz im Zeichen steht der Kurztext darunter.
    private static func hasCaption(_ sign: TacticalSign) -> Bool {
        guard !sign.text.isEmpty else { return false }
        switch sign.base {
        case .hubschrauber, .person, .personVerletzt, .personTot, .personZuTransportieren, .gefahr, .gefahrAkut, .massnahme: return true
        default: return false
        }
    }

    /// Gefüllte Fläche (für Füllung und Ausschnitt der Fachaufgabe).
    private static func bodyPath(_ base: TacticalBase) -> CGPath {
        let path = CGMutablePath()
        switch base {
        case .stelle:
            path.addEllipse(in: CGRect(x: 1, y: 1, width: 43, height: 43))
        case .gebaeude:
            path.addRect(CGRect(x: 1, y: 10, width: 73, height: 34))
        case .fahrzeug, .kraftfahrzeug:
            path.move(to: CGPoint(x: 1, y: 44))
            path.addLine(to: CGPoint(x: 1, y: 1))
            path.addQuadCurve(to: CGPoint(x: 74, y: 1), control: CGPoint(x: 37.5, y: 10))
            path.addLine(to: CGPoint(x: 74, y: 44))
            path.closeSubpath()
        default:
            path.addRect(CGRect(x: 1, y: 1, width: 73, height: 43))
        }
        return path
    }

    /// Umriss (Befehlsstelle mit Fahnenstock, Gebäude mit Dach).
    private static func outlinePath(_ base: TacticalBase) -> CGPath {
        switch base {
        case .befehlsstelle:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 1, y: 55))
            path.addLine(to: CGPoint(x: 1, y: 1))
            path.addLine(to: CGPoint(x: 74, y: 1))
            path.addLine(to: CGPoint(x: 74, y: 44))
            path.addLine(to: CGPoint(x: 1, y: 44))
            return path
        case .gebaeude:
            let path = CGMutablePath(rect: CGRect(x: 1, y: 10, width: 73, height: 34), transform: nil)
            path.move(to: CGPoint(x: 1, y: 10))
            path.addLine(to: CGPoint(x: 37.5, y: 1))
            path.addLine(to: CGPoint(x: 74, y: 10))
            return path
        default:
            return bodyPath(base)
        }
    }

    /// Fläche, über die das Fachaufgaben-Kreuz läuft.
    private static func taskFrame(_ base: TacticalBase) -> CGRect {
        switch base {
        case .stelle: CGRect(x: 0, y: 0, width: 45, height: 45)
        case .gebaeude: CGRect(x: 0, y: 10, width: 75, height: 35)
        default: CGRect(x: 0, y: 0, width: 75, height: 45)
        }
    }

    private static func drawTask(_ task: TacticalTask, in frame: CGRect, color: UIColor, context: CGContext) {
        // Raster der Vorlage 75 × 45 auf die Fläche abbilden.
        let sx = frame.width / 75, sy = frame.height / 45
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: frame.minX + x * sx, y: frame.minY + y * sy) }
        context.setStrokeColor(color.cgColor)
        context.move(to: p(0, 22.5)); context.addLine(to: p(75, 22.5))
        context.move(to: p(37.5, 0)); context.addLine(to: p(37.5, 45))
        switch task {
        case .rettungswesen:
            break
        case .aerztlicheVersorgung:
            context.move(to: p(25, 33)); context.addLine(to: p(50, 33))
        case .krankenhaus:
            context.move(to: p(20, 14.5)); context.addLine(to: p(20, 30.5))
            context.move(to: p(55, 14.5)); context.addLine(to: p(55, 30.5))
        }
        context.strokePath()
    }

    /// Textfeld: mit Kreuz unten links (wie das Typfeld der Vorlage), sonst mittig.
    private static func textFrame(_ sign: TacticalSign) -> CGRect {
        let hasTask = sign.task != nil
        switch sign.base {
        case .stelle:
            return hasTask ? CGRect(x: 6, y: 25, width: 15, height: 12) : CGRect(x: 5, y: 12, width: 35, height: 21)
        case .gebaeude:
            return hasTask ? CGRect(x: 3, y: 33, width: 32, height: 10) : CGRect(x: 4, y: 14, width: 67, height: 26)
        default:
            return hasTask ? CGRect(x: 3, y: 26, width: 32, height: 16) : CGRect(x: 5, y: 8, width: 65, height: 30)
        }
    }

    private static func drawText(_ text: String, in frame: CGRect, color: UIColor, context: CGContext) {
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        var fontSize = frame.height * 0.85
        var attributes: [NSAttributedString.Key: Any] = [:]
        var size = CGSize.zero
        repeat {
            attributes = [.font: UIFont.systemFont(ofSize: fontSize, weight: .heavy), .foregroundColor: color]
            size = (text as NSString).size(withAttributes: attributes)
            if size.width <= frame.width { break }
            fontSize -= 0.5
        } while fontSize > 4
        let point = CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        (text as NSString).draw(at: point, withAttributes: attributes)
    }

    /// Kurztext unter dem Zeichen auf hellem Grund (lesbar auf jeder Karte).
    private static func drawCaption(_ text: String, in frame: CGRect, scale: CGFloat, context: CGContext) {
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: frame.height * 0.8, weight: .heavy),
            .foregroundColor: UIColor.black,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let box = CGRect(x: frame.midX - size.width / 2 - 3 * scale, y: frame.minY, width: size.width + 6 * scale, height: frame.height)
        UIColor.white.withAlphaComponent(0.9).setFill()
        UIBezierPath(roundedRect: box, cornerRadius: 3 * scale).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 3 * scale, y: box.midY - size.height / 2), withAttributes: attributes)
    }

    // MARK: Personen, Gefahren, Hubschrauber

    private static func drawPerson(_ sign: TacticalSign, fill: UIColor, in context: CGContext) {
        let diamond = CGMutablePath()
        diamond.move(to: CGPoint(x: 22.5, y: 1.5))
        diamond.addLine(to: CGPoint(x: 43.5, y: 22.5))
        diamond.addLine(to: CGPoint(x: 22.5, y: 43.5))
        diamond.addLine(to: CGPoint(x: 1.5, y: 22.5))
        diamond.closeSubpath()
        context.addPath(diamond)
        context.setFillColor(fill.cgColor)
        context.setStrokeColor(UIColor.black.cgColor)
        context.drawPath(using: .fillStroke)
        switch sign.base {
        case .personVerletzt:
            context.move(to: CGPoint(x: 22.5, y: 1.5)); context.addLine(to: CGPoint(x: 22.5, y: 43.5))
        case .personTot:
            context.move(to: CGPoint(x: 22.5, y: 1.5)); context.addLine(to: CGPoint(x: 22.5, y: 43.5))
            context.move(to: CGPoint(x: 14, y: 10)); context.addLine(to: CGPoint(x: 31, y: 10))
        case .personZuTransportieren:
            context.move(to: CGPoint(x: 0, y: 46)); context.addLine(to: CGPoint(x: 43, y: 46))
            context.strokePath()
            context.move(to: CGPoint(x: 39, y: 43)); context.addLine(to: CGPoint(x: 44, y: 46)); context.addLine(to: CGPoint(x: 39, y: 49))
            context.closePath()
            context.setFillColor(UIColor.black.cgColor)
            context.fillPath()
        default:
            break
        }
        context.strokePath()
    }

    private static func drawHazardOrMeasure(_ sign: TacticalSign, in context: CGContext) {
        let triangle = CGMutablePath()
        let color: UIColor
        switch sign.base {
        case .massnahme:
            color = measureBlue
            triangle.move(to: CGPoint(x: 22.5, y: 34))
            triangle.addLine(to: CGPoint(x: 43.2, y: 1))
            triangle.addLine(to: CGPoint(x: 1.8, y: 1))
        case .gefahrAkut:
            color = hazardRed
            triangle.move(to: CGPoint(x: 28, y: 2))
            triangle.addLine(to: CGPoint(x: 48.7, y: 35))
            triangle.addLine(to: CGPoint(x: 7.3, y: 35))
        default:
            color = hazardRed
            triangle.move(to: CGPoint(x: 22.5, y: 1.8))
            triangle.addLine(to: CGPoint(x: 43.2, y: 35))
            triangle.addLine(to: CGPoint(x: 1.8, y: 35))
        }
        triangle.closeSubpath()
        context.addPath(triangle)
        context.setFillColor(UIColor.white.cgColor)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth * 1.5)
        context.drawPath(using: .fillStroke)
        if sign.base == .gefahrAkut {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 1, y: 3, width: 4.5, height: 15))
            context.fill(CGRect(x: 1, y: 20, width: 4.5, height: 4))
        }
    }

    private static func drawHelicopter(fill: UIColor, in context: CGContext) {
        // Symbol der Vorlage (38 × 23) um 1,6 vergrößert.
        context.saveGState()
        context.scaleBy(x: 1.6, y: 1.6)
        context.setLineWidth(lineWidth / 1.6)
        context.setStrokeColor(UIColor.black.cgColor)
        context.move(to: CGPoint(x: 19, y: 2)); context.addLine(to: CGPoint(x: 19, y: 22))
        context.move(to: CGPoint(x: 9, y: 22)); context.addLine(to: CGPoint(x: 29, y: 22))
        context.strokePath()
        for x in [5.0, 23.0] {
            let blade = UIBezierPath(roundedRect: CGRect(x: x - 4, y: 1, width: 18, height: 8), cornerRadius: 4).cgPath
            context.addPath(blade)
            context.setFillColor(fill.cgColor)
            context.drawPath(using: .fillStroke)
        }
        context.restoreGState()
    }

    private static func drawUnitSize(_ size: TacticalUnitSize, centerX: CGFloat, top: CGFloat, scale: CGFloat, in context: CGContext) {
        let radius = 2.2 * scale
        let step = 7 * scale
        let y = top + 5 * scale
        let positions: [CGPoint]
        switch size {
        case .trupp: positions = [CGPoint(x: centerX, y: y)]
        case .staffel: positions = [CGPoint(x: centerX, y: y - 3 * scale), CGPoint(x: centerX, y: y + 3 * scale)]
        case .gruppe: positions = [CGPoint(x: centerX - step / 2, y: y), CGPoint(x: centerX + step / 2, y: y)]
        case .zug: positions = [CGPoint(x: centerX - step, y: y), CGPoint(x: centerX, y: y), CGPoint(x: centerX + step, y: y)]
        }
        context.setFillColor(UIColor.black.cgColor)
        for point in positions {
            context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        }
    }
}

import Foundation
import ELRDDomain

// MARK: - Kartenobjekte (Kreise, Rechtecke)

/// Liest ein aktives Kartenobjekt oder meldet „nicht gefunden“.
@MainActor
private func activeMapObject(_ id: MapObjectID, in draft: MissionDraft) throws -> MapObject {
    guard let object = draft.get(MapObject.self, id: id), !object.metadata.isDeleted else {
        throw CommandError.notFound(.mapObject)
    }
    return object
}

/// Legt einen Kreis oder ein Rechteck auf der Lagekarte an.
public struct AddMapObject: MissionCommand {
    public let shape: MapShape
    public let title: String
    public let color: RGBColor
    /// Schritt 114: taktisches Zeichen (Form = kleiner Kreis um den Standort).
    public let tacticalSign: TacticalSign?
    /// Schritt 115: Polygon oder Pfeil (Form wird zum umgebenden Rechteck).
    public let path: MapPath?

    public init(shape: MapShape, title: String = "", color: RGBColor = MapObject.defaultColor,
                tacticalSign: TacticalSign? = nil, path: MapPath? = nil) {
        self.shape = shape
        self.title = title
        self.color = color
        self.tacticalSign = tacticalSign
        self.path = path
    }

    /// Taktisches Zeichen an einem Punkt.
    public static func sign(_ sign: TacticalSign, at coordinate: GeoCoordinate, title: String = "") -> AddMapObject {
        AddMapObject(shape: .circle(center: coordinate, radiusMeters: 10), title: title,
                     color: sign.isHazard ? MapObject.defaultColor : sign.organisation.fill, tacticalSign: sign)
    }

    /// Polygon oder Pfeil; `nil` bei zu wenigen Punkten.
    public static func withPath(_ path: MapPath, title: String = "", color: RGBColor = MapObject.defaultColor) -> AddMapObject? {
        guard path.isValid, let shape = path.fallbackShape else { return nil }
        return AddMapObject(shape: shape, title: title, color: color, path: path)
    }

    public func execute(_ draft: inout MissionDraft) throws -> MapObject {
        guard var object = MapObject(
            missionID: draft.missionID,
            metadata: draft.context.newMetadata(),
            title: title,
            color: color,
            shape: shape
        ) else {
            throw CommandError.invalid("Diese Form ist ungültig (Radius 1 m bis 50 km).")
        }
        object.tacticalSign = tacticalSign
        if let path, !object.setPath(path) {
            throw CommandError.invalid(path.kind == .polygon ? "Eine Fläche braucht mindestens drei Punkte." : "Ein Pfeil braucht mindestens zwei Punkte.")
        }
        try draft.insert(object)
        draft.log(.map, "„\(object.displayName)“ auf der Karte angelegt (\(object.sizeText))", subject: .mapObject(object.id))
        return object
    }
}

/// Ändert Titel, Notiz, Farbe oder Form eines Kartenobjekts (`nil`: unverändert).
public struct EditMapObject: MissionCommand {
    public let objectID: MapObjectID
    public let title: String?
    public let note: String?
    public let color: RGBColor?
    public let shape: MapShape?
    /// Schritt 114/115: Zeichen bzw. Linienzug ändern (`nil`: unverändert).
    public let tacticalSign: TacticalSign?
    public let path: MapPath?

    public init(objectID: MapObjectID, title: String? = nil, note: String? = nil, color: RGBColor? = nil, shape: MapShape? = nil,
                tacticalSign: TacticalSign? = nil, path: MapPath? = nil) {
        self.objectID = objectID
        self.title = title
        self.note = note
        self.color = color
        self.shape = shape
        self.tacticalSign = tacticalSign
        self.path = path
    }

    public func execute(_ draft: inout MissionDraft) throws {
        let before = try activeMapObject(objectID, in: draft)
        if let shape, !shape.isValid {
            throw CommandError.invalid("Diese Form ist ungültig (Radius 1 m bis 50 km).")
        }
        if let path, !path.isValid {
            throw CommandError.invalid("Zu wenige Punkte für diese Form.")
        }
        let newTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newNote = note
        let newColor = color
        let newShape = shape
        let newSign = tacticalSign
        let newPath = path
        try draft.update(MapObject.self, id: objectID) { object in
            if let newTitle { object.title = newTitle }
            if let newNote { object.note = newNote }
            if let newColor { object.color = newColor }
            if let newShape { object.setShape(newShape) }
            if let newSign { object.tacticalSign = newSign }
            if let newPath { object.setPath(newPath) }
        }
        guard let after = draft.get(MapObject.self, id: objectID),
              after.title != before.title || after.note != before.note
                || after.color != before.color || after.shape != before.shape
                || after.tacticalSign != before.tacticalSign || after.path != before.path else { return }
        let detail: String
        if after.shape != before.shape, after.shape.center != before.shape.center, after.shape.sizeText == before.shape.sizeText {
            detail = "verschoben"
        } else if after.shape != before.shape || after.path != before.path {
            detail = "geändert (\(after.sizeText))"
        } else if after.title != before.title {
            detail = before.title.isEmpty ? "benannt" : "umbenannt (vorher „\(before.displayName)“)"
        } else {
            detail = "geändert"
        }
        draft.log(.map, "„\(after.displayName)“ \(detail)", subject: .mapObject(objectID))
    }
}

/// Löscht ein Kartenobjekt (weich).
public struct DeleteMapObject: MissionCommand {
    public let objectID: MapObjectID

    public init(objectID: MapObjectID) {
        self.objectID = objectID
    }

    public func execute(_ draft: inout MissionDraft) throws {
        let object = try activeMapObject(objectID, in: draft)
        try draft.delete(MapObject.self, id: objectID)
        draft.log(.map, "„\(object.displayName)“ von der Karte gelöscht", subject: .mapObject(objectID))
    }
}

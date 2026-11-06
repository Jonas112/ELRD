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

    public init(shape: MapShape, title: String = "", color: RGBColor = MapObject.defaultColor) {
        self.shape = shape
        self.title = title
        self.color = color
    }

    public func execute(_ draft: inout MissionDraft) throws -> MapObject {
        guard let object = MapObject(
            missionID: draft.missionID,
            metadata: draft.context.newMetadata(),
            title: title,
            color: color,
            shape: shape
        ) else {
            throw CommandError.invalid("Diese Form ist ungültig (Radius 1 m bis 50 km).")
        }
        try draft.insert(object)
        draft.log(.map, "„\(object.displayName)“ auf der Karte angelegt (\(object.shape.sizeText))", subject: .mapObject(object.id))
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

    public init(objectID: MapObjectID, title: String? = nil, note: String? = nil, color: RGBColor? = nil, shape: MapShape? = nil) {
        self.objectID = objectID
        self.title = title
        self.note = note
        self.color = color
        self.shape = shape
    }

    public func execute(_ draft: inout MissionDraft) throws {
        let before = try activeMapObject(objectID, in: draft)
        if let shape, !shape.isValid {
            throw CommandError.invalid("Diese Form ist ungültig (Radius 1 m bis 50 km).")
        }
        let newTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newNote = note
        let newColor = color
        let newShape = shape
        try draft.update(MapObject.self, id: objectID) { object in
            if let newTitle { object.title = newTitle }
            if let newNote { object.note = newNote }
            if let newColor { object.color = newColor }
            if let newShape { object.setShape(newShape) }
        }
        guard let after = draft.get(MapObject.self, id: objectID),
              after.title != before.title || after.note != before.note
                || after.color != before.color || after.shape != before.shape else { return }
        let detail: String
        if after.shape != before.shape, after.shape.center != before.shape.center, after.shape.sizeText == before.shape.sizeText {
            detail = "verschoben"
        } else if after.shape != before.shape {
            detail = "geändert (\(after.shape.sizeText))"
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

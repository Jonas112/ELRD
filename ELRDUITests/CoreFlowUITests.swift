import XCTest

/// Oberflächentests der Kernabläufe (Schritt 65) mit den Beispieldaten
/// (`--demo-screen`). Abgefragt wird über die VoiceOver-Beschriftungen – damit
/// prüfen die Tests nebenbei, dass die Knöpfe sinnvoll beschriftet sind.
@MainActor
final class CoreFlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-screen", screen]
        app.launch()
        return app
    }

    private func button(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    /// Scrollt, bis das Element antippbar ist (lange Ansichten, kleine Bildschirme).
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        var attempts = 0
        while !element.isHittable, attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
    }

    func testContinueRunningMissionFromList() {
        let app = launch("missions")
        let resume = button(app, containing: "Fortsetzen")
        XCTAssertTrue(resume.waitForExistence(timeout: 30))
        resume.tap()
        XCTAssertTrue(app.buttons["Neuer Patient"].waitForExistence(timeout: 10), "Arbeitsbereich des Einsatzes offen")
    }

    func testQuickAddCreatesPatient() {
        let app = launch("workspace")
        let add = app.buttons["Neuer Patient"]
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        add.tap()
        let sk1 = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Patient' AND label ENDSWITH 'anlegen'")).firstMatch
        XCTAssertTrue(sk1.waitForExistence(timeout: 10))
        sk1.tap()
        let notice = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'angelegt'")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "Hinweis „… angelegt“ erscheint")
    }

    func testAssignTransportFromList() {
        let app = launch("patientDetail")
        // Nicht der Bereich „Einheiten“ in der Leiste, sondern der Knopf am Patienten.
        let open = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Alle Einheiten' OR label BEGINSWITH 'Einheit wählen'")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 30))
        reveal(open, in: app)
        open.tap()
        XCTAssertTrue(app.navigationBars["Transportmittel"].waitForExistence(timeout: 10))
        // Kachel in der Liste („…, frei“), nicht der Vorschlag am Patienten dahinter.
        let rtw = app.buttons.matching(NSPredicate(format: "label CONTAINS 'RK SWFT 71/1' AND label CONTAINS 'frei'")).firstMatch
        XCTAssertTrue(rtw.waitForExistence(timeout: 10))
        rtw.tap()
        // Transportmittel gewählt → Liste schließt sich, am Patienten steht „ändern“.
        XCTAssertTrue(app.navigationBars["Transportmittel"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(button(app, containing: "RK SWFT 71/1").waitForExistence(timeout: 10))
    }

    func testReportOpensWithOutputButtons() {
        let app = launch("workspace")
        let report = app.buttons["Bericht erstellen"]
        XCTAssertTrue(report.waitForExistence(timeout: 30))
        report.tap()
        XCTAssertTrue(button(app, containing: "An ILS").waitForExistence(timeout: 30), "Bericht mit Versandknopf")
        XCTAssertTrue(button(app, containing: "Drucken").exists)
    }
}

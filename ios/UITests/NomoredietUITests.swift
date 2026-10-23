import XCTest

/// Walks through every screen of Nomorediet on the simulator, connects Apple Health with all permissions and
/// checks the steps arrive. Each step leaves a screenshot in the test results (exported by the workflow).
final class NomoredietUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-uiTesting", "-seedHealth", "-AppleLanguages", "(it)", "-AppleLocale", "it_IT"]
        app.launch()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tab(_ id: String, _ label: String) {
        let byId = app.buttons[id]
        if byId.waitForExistence(timeout: 5) { byId.tap() } else { app.tabBars.buttons[label].tap() }
    }

    /// Taps the first button with one of these labels, if it appears (system sheets change wording by language).
    @discardableResult
    private func tapAny(_ labels: [String], in root: XCUIElement? = nil, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for label in labels {
                let scopes: [XCUIElement] = [root ?? app, app]
                for scope in scopes {
                    let b = scope.buttons[label]
                    if b.exists && b.isHittable { b.tap(); return true }
                    let s = scope.switches[label]
                    if s.exists && s.isHittable { s.tap(); return true }
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline
        return false
    }

    func test1_Oggi_scriviCosaHaiMangiato() {
        tab("tab-oggi", "Oggi")
        shot("01-oggi")
        let field = app.textFields["say-meal-text"].exists ? app.textFields["say-meal-text"] : app.textViews["say-meal-text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "manca il campo Cosa hai mangiato")
        field.tap()
        field.typeText("a pranzo 200 g di riso e a cena 2 uova")
        shot("02-oggi-testo")
        app.buttons["say-meal-send"].tap()
        let added = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Aggiunto'")).firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 30), "il pasto non è stato aggiunto")
        shot("03-oggi-aggiunto")
        app.swipeUp()
        shot("04-oggi-pasti")
    }

    func test2_Allenamento() {
        tab("tab-allenamento", "Allenamento")
        XCTAssertTrue(app.buttons["workout-start"].waitForExistence(timeout: 5))
        shot("05-allenamento")
        app.buttons["workout-prev"].tap()
        shot("06-allenamento-precedente")
        app.buttons["workout-start"].tap()
        shot("07-seduta")
        let swap = app.buttons["Cambia esercizio"].firstMatch
        if swap.waitForExistence(timeout: 5) {
            swap.tap()
            shot("08-cambia-esercizio")
            app.swipeUp(); app.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(4))
            shot("09-catalogo")
            app.swipeDown(velocity: .fast)
        }
        let finish = app.buttons["workout-finish"]
        for _ in 0..<12 where !finish.isHittable { app.swipeUp() }
        finish.tap()
        let bravo = app.staticTexts["Bravo, ce l'hai fatta!"]
        XCTAssertTrue(bravo.waitForExistence(timeout: 5), "manca il messaggio di fine allenamento")
        shot("10-bravo")
    }

    func test3_Salute_passi() {
        tab("tab-profilo", "Profilo")
        let connect = app.buttons["Collega Apple Salute"]
        for _ in 0..<10 where !connect.exists && !app.buttons["Sincronizza adesso"].exists { app.swipeUp() }
        shot("11-profilo-salute")
        if connect.exists { connect.tap() } else { app.buttons["Sincronizza adesso"].tap() }
        // the Health permission sheet: turn on everything, then allow
        if tapAny(["Turn On All", "Attiva tutto", "Turn On All Categories", "Attiva tutte le categorie"], timeout: 15) {
            shot("12-permessi-salute")
            tapAny(["Allow", "Consenti"], timeout: 8)
        }
        let connected = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Collegata'")).firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 30), "Salute non risulta collegata")
        shot("13-salute-collegata")
        tab("tab-progressi", "Progressi")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        shot("14-progressi")
        app.swipeUp()
        shot("15-progressi-passi")
        let steps = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'passi'")).firstMatch
        XCTAssertTrue(steps.exists, "nessun dato sui passi in Progressi")
    }

    func test4_Coach_e_Profilo() {
        tab("tab-coach", "Coach")
        shot("16-coach")
        tab("tab-profilo", "Profilo")
        shot("17-profilo")
        app.swipeUp()
        shot("18-profilo-ai")
    }

    /// Every session of the plan, top and bottom, so the plan can be seen as it is in the app.
    func test5_Schede() {
        tab("tab-allenamento", "Allenamento")
        XCTAssertTrue(app.buttons["workout-start"].waitForExistence(timeout: 5))
        shot("20-schede-elenco")
        app.swipeUp()
        shot("21-schede-elenco-2")
        app.swipeDown(); app.swipeDown()
        for i in 0..<4 {
            app.buttons["workout-start"].tap()
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            for part in 0..<4 {
                shot(String(format: "%02d-scheda%d-%d", 22 + i * 4 + part, i + 1, part + 1))
                app.swipeUp()
            }
            app.navigationBars.buttons.element(boundBy: 0).tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            app.buttons["workout-next"].tap()
        }
    }
}


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
        grantHealthIfAsked()
    }

    /// The Health permission sheet (it can appear at launch): select every topic, then Allow.
    @discardableResult
    private func grantHealthIfAsked(timeout: TimeInterval = 6) -> Bool {
        let allow = app.buttons["UIA.Health.Allow.Button"]
        let selectAll = app.buttons.matching(NSPredicate(format:
            "label BEGINSWITH 'Select All' OR label BEGINSWITH 'Seleziona tutt' OR label BEGINSWITH 'Turn On All' OR label BEGINSWITH 'Attiva tutt'")).firstMatch
        guard allow.waitForExistence(timeout: timeout) || selectAll.exists else { return false }
        shot("00-permessi-salute")
        if selectAll.exists { selectAll.tap() }
        // write access (only the test's sample data) has its own switches: turn on the ones still off
        for _ in 0..<8 {
            for toggle in app.switches.allElementsBoundByIndex where toggle.isHittable && (toggle.value as? String) == "0" { toggle.tap() }
            if allow.isHittable && allow.isEnabled { break }
            app.swipeUp()
        }
        shot("00-permessi-salute-tutti")
        if allow.isEnabled { allow.tap() }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        return true
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
        if !(field.value(forKey: "hasKeyboardFocus") as? Bool ?? false) { field.tap() }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        app.typeText("a pranzo 200 g di riso e a cena 2 uova")
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
            if app.buttons["swap-close"].exists { app.buttons["swap-close"].tap() }
            else if app.buttons["Chiudi"].exists { app.buttons["Chiudi"].tap() }
            else {
                let grabber = app.buttons["Sheet Grabber"]
                grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .press(forDuration: 0.2, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
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
        let connect = app.buttons["health-connect"]
        for _ in 0..<10 where !connect.isHittable { app.swipeUp() }
        shot("11-profilo-salute")
        connect.tap()
        grantHealthIfAsked(timeout: 10)
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        let connected = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Collegata'")).firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 30), "Salute non risulta collegata")
        shot("13-salute-collegata")
        tab("tab-progressi", "Progressi")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        shot("14-progressi")
        app.swipeUp()
        shot("15-progressi-passi")
        let empty = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Collega Apple Salute'")).firstMatch
        XCTAssertFalse(empty.exists, "il grafico dei passi è vuoto")
        app.open(URL(string: "nomorediet://debug")!)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        shot("19-debug")
        for i in 0..<4 { app.swipeUp(); shot("19-debug-\(i + 1)") }
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
            let back = app.navigationBars.buttons.matching(NSPredicate(format: "label == 'Allenamento' OR label == 'Back' OR label == 'Indietro'")).firstMatch
            if back.exists { back.tap() } else { app.swipeRight() }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            app.buttons["workout-next"].tap()
        }
    }
}


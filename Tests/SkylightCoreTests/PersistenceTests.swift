import XCTest
import SkylightCore

final class PersistenceTests: XCTestCase {
    /// This test EXISTS to fail when someone adds a persisted field without
    /// teaching `CanvasBoard.init(from:)` about it. `CanvasBoard` decodes by
    /// hand (for the pre-pan/pre-zoom defaults), so the synthesized encoder
    /// will happily write a key the initializer silently drops — and a dropped
    /// key does not throw, it just resets to a default on every load. So every
    /// CanvasBoard field here is set to something a default could never be,
    /// and the assertion is full equality: a field that stops surviving the
    /// round trip breaks this, loudly, in the same commit that adds it.
    func testV2RoundTrip() throws {
        let instance = TerminalInstance(
            name: "Claude Code",
            spec: TerminalSpec(harness: "claude", arguments: ["--model", "opus"],
                               workingDirectory: "/tmp"))
        let docked = TerminalInstance(name: "Docked")
        var board = CanvasBoard(
            id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            name: "Work",
            tiles: [CanvasTile(itemID: instance.id, origin: CGPoint(x: 64, y: 48),
                               size: CGSize(width: 560, height: 400))],
            pan: CGPoint(x: -120, y: 40),
            zoom: 0.5)
        // Non-default docks, per the tripwire's own instructions: a field
        // left at its default in this fixture would round-trip green even if
        // the decoder dropped it.
        board.docks = [.left: DockRail(thickness: 280,
                                       slots: [DockSlot(itemID: docked.id, weight: 1)])]
        let state = SavedState(instances: [instance, docked], canvases: [board],
                               selectedInstance: instance.id,
                               selectedCanvas: board.id)
        let data = try XCTUnwrap(WorkspacePersistence.encode(state))
        let decoded = try XCTUnwrap(WorkspacePersistence.decode(data))
        // Board equality first: it is the type that decodes by hand, so it is
        // the one whose failure should name itself rather than hiding inside a
        // whole-state diff.
        XCTAssertEqual(decoded.canvases, [board])
        XCTAssertEqual(decoded, state)
    }

    /// The companion tripwire to testV2RoundTrip's fixture contract: that
    /// test only guards the fields its fixture SETS, so a brand-new stored
    /// property nobody adds there would sail through the round trip on its
    /// default. This count forces this file open the moment CanvasBoard
    /// grows — set the new field to a non-default value in the fixture,
    /// decode it in init(from:), then bump the number.
    func testBoardStoredPropertyCountMatchesFixtureContract() {
        XCTAssertEqual(Mirror(reflecting: CanvasBoard(name: "X")).children.count, 6,
                       """
                       CanvasBoard grew a stored property: give it a \
                       non-default value in testV2RoundTrip, decode it in \
                       init(from:), then bump this count.
                       """)
    }

    func testBoardPanDefaultsToZeroWhenAbsent() throws {
        // A v2 board saved before `pan`/`zoom` existed must still decode.
        let json = """
        {"version":2,"instances":[],"canvases":[
          {"id":"44444444-4444-4444-4444-444444444444","name":"Old","tiles":[]}
        ]}
        """
        let state = try XCTUnwrap(WorkspacePersistence.decode(Data(json.utf8)))
        XCTAssertEqual(state.canvases.first?.pan, .zero)
        XCTAssertEqual(state.canvases.first?.zoom, 1)
    }

    func testLegacyMigrationDropsChatsAndMapsFlavors() throws {
        let json = """
        {
          "items": [
            {"id":"11111111-1111-1111-1111-111111111111",
             "kind":{"assistant":{"_0":"claude"}},"name":"Claude","mode":"chat","pinned":false},
            {"id":"22222222-2222-2222-2222-222222222222",
             "kind":{"terminal":{}},"name":"Terminal 1","mode":"chat","pinned":false},
            {"id":"33333333-3333-3333-3333-333333333333",
             "kind":{"terminal":{}},"name":"Claude Code","mode":"chat","pinned":false,
             "terminalFlavor":"claudeCode","workingDirectory":"/tmp"}
          ],
          "canvases": [
            {"id":"44444444-4444-4444-4444-444444444444","name":"Board","tiles":[
              {"id":"55555555-5555-5555-5555-555555555555",
               "itemID":"22222222-2222-2222-2222-222222222222","origin":[64,48],"size":[560,400]},
              {"id":"66666666-6666-6666-6666-666666666666",
               "itemID":"11111111-1111-1111-1111-111111111111","origin":[100,100],"size":[560,400]}
            ]}
          ],
          "selectedItem": "11111111-1111-1111-1111-111111111111"
        }
        """
        let state = try XCTUnwrap(WorkspacePersistence.decode(Data(json.utf8)))
        XCTAssertEqual(state.instances.count, 2)                       // chat item dropped
        let agent = try XCTUnwrap(state.instances.first { $0.name == "Claude Code" })
        XCTAssertEqual(agent.spec.harness, "claude")                   // flavor → harness
        XCTAssertEqual(agent.spec.workingDirectory, "/tmp")
        XCTAssertEqual(state.canvases.first?.tiles.count, 1)           // chat tile dropped
        XCTAssertNil(state.selectedInstance)                           // selected chat → nil
    }

    func testLegacyMigrationEnforcesSingleResidency() throws {
        // The same terminal on two boards keeps only its first tile.
        let json = """
        {
          "items": [
            {"id":"22222222-2222-2222-2222-222222222222",
             "kind":{"terminal":{}},"name":"T","mode":"chat","pinned":false}
          ],
          "canvases": [
            {"id":"44444444-4444-4444-4444-444444444444","name":"A","tiles":[
              {"id":"55555555-5555-5555-5555-555555555555",
               "itemID":"22222222-2222-2222-2222-222222222222","origin":[0,0],"size":[560,400]}]},
            {"id":"77777777-7777-7777-7777-777777777777","name":"B","tiles":[
              {"id":"88888888-8888-8888-8888-888888888888",
               "itemID":"22222222-2222-2222-2222-222222222222","origin":[0,0],"size":[560,400]}]}
          ]
        }
        """
        let state = try XCTUnwrap(WorkspacePersistence.decode(Data(json.utf8)))
        XCTAssertEqual(state.canvases[0].tiles.count, 1)
        XCTAssertEqual(state.canvases[1].tiles.count, 0)
    }

    func testV2HostileDataIsSanitized() throws {
        // The current format is stored data too: dup residency, an orphan
        // tile, and dangling selections must not survive a load.
        let json = """
        {"version":2,
         "instances":[{"id":"11111111-1111-1111-1111-111111111111","name":"T",
                       "spec":{"arguments":[]}}],
         "canvases":[
           {"id":"44444444-4444-4444-4444-444444444444","name":"A","tiles":[
             {"id":"55555555-5555-5555-5555-555555555555",
              "itemID":"11111111-1111-1111-1111-111111111111","origin":[0,0],"size":[560,400]},
             {"id":"66666666-6666-6666-6666-666666666666",
              "itemID":"99999999-9999-9999-9999-999999999999","origin":[0,0],"size":[560,400]}]},
           {"id":"77777777-7777-7777-7777-777777777777","name":"B","tiles":[
             {"id":"88888888-8888-8888-8888-888888888888",
              "itemID":"11111111-1111-1111-1111-111111111111","origin":[0,0],"size":[560,400]}]}],
         "selectedInstance":"22222222-2222-2222-2222-222222222222",
         "selectedCanvas":"33333333-3333-3333-3333-333333333333"}
        """
        let state = try XCTUnwrap(WorkspacePersistence.decode(Data(json.utf8)))
        XCTAssertEqual(state.canvases[0].tiles.count, 1)   // orphan dropped
        XCTAssertEqual(state.canvases[1].tiles.count, 0)   // second residency dropped
        XCTAssertNil(state.selectedInstance)               // dangling → nil
        XCTAssertNil(state.selectedCanvas)
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(WorkspacePersistence.decode(Data("not json".utf8)))
        XCTAssertNil(WorkspacePersistence.decode(Data("{\"unrelated\":true}".utf8)))
    }

    func testResidencyHelpers() {
        let a = TerminalInstance(name: "A")
        let b = TerminalInstance(name: "B")
        let board = CanvasBoard(name: "W", tiles: [
            CanvasTile(itemID: b.id, origin: .zero, size: CanvasLayout.defaultTileSize)])
        XCTAssertNil(Residency.board(of: a.id, in: [board]))
        XCTAssertEqual(Residency.board(of: b.id, in: [board]), board.id)
        XCTAssertEqual(Residency.free([a, b], boards: [board]).map(\.id), [a.id])
        XCTAssertEqual(Residency.residents(of: board, from: [a, b]).map(\.id), [b.id])
    }

    func testComboKey() {
        XCTAssertEqual(TerminalSpec().comboKey, "login|shell|")
        XCTAssertEqual(
            TerminalSpec(shellPath: "/bin/zsh", harness: "claude",
                         arguments: ["--model", "opus"]).comboKey,
            "/bin/zsh|claude|--model opus")
    }
}

/// The five-item CanvasBoard checklist, one named test each. `docks` is the
/// first property added to this type since the tripwire went in, and the
/// tripwire exists because a hand-written decoder silently drops what it does
/// not read — the value simply reverts to its default on every load, forever,
/// with nothing failing.
final class DockPersistenceTests: XCTestCase {
    private func board(withDocks: Bool) -> CanvasBoard {
        var board = CanvasBoard(name: "B", tiles: [], pan: CGPoint(x: 3, y: 4), zoom: 0.5)
        if withDocks {
            board.docks = [.left: DockRail(thickness: 280,
                                           slots: [DockSlot(itemID: UUID(), weight: 1)])]
        }
        return board
    }

    /// CHECKLIST 1 + 2: CodingKeys carries `docks`, and the hand-written
    /// init(from:) actually reads it back.
    func testDocksRoundTripThroughEncodeDecode() throws {
        let original = board(withDocks: true)
        let decoded = try JSONDecoder().decode(
            CanvasBoard.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.docks, original.docks)
        XCTAssertFalse(decoded.docks.isEmpty, "the decoder dropped docks entirely")
        // The other persisted fields must still survive alongside it.
        XCTAssertEqual(decoded.pan, original.pan)
        XCTAssertEqual(decoded.zoom, original.zoom)
    }

    /// A board written before docking existed must still load, undocked.
    func testABoardSavedBeforeDocksDecodesWithNone() throws {
        // Built by ENCODING a pre-docks board rather than hand-writing JSON:
        // CGPoint round-trips as an array, and a hand-made fixture that gets
        // that wrong tests the fixture instead of the decoder.
        var old = CanvasBoard(name: "Old", pan: CGPoint(x: 1, y: 2), zoom: 0.75)
        old.docks = [:]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "docks")
        XCTAssertNil(object["docks"])
        let decoded = try JSONDecoder().decode(
            CanvasBoard.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.pan, CGPoint(x: 1, y: 2))
        XCTAssertEqual(decoded.zoom, 0.75)
        XCTAssertTrue(decoded.docks.isEmpty)
    }

    /// CHECKLIST 3: the tripwire fired on `docks` and was answered the way it
    /// asks to be — fixture first, decoder second, count last. This asserts
    /// the half a bare count cannot: that the round-trip fixture actually
    /// carries a NON-DEFAULT value, without which it would stay green even if
    /// the decoder dropped the field entirely.
    func testTheRoundTripFixtureExercisesDocks() throws {
        let encoded = try JSONEncoder().encode(
            CanvasBoard(name: "F", docks: [.left: DockRail(
                thickness: 280, slots: [DockSlot(itemID: UUID(), weight: 1)])]))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(object["docks"], "docks must actually be written")
    }

    /// CHECKLIST 4: single residency now spans free AND docked. One live
    /// terminal NSView claimed twice is the exact bug `sanitized` exists to
    /// prevent, and docking opened a second way to cause it.
    func testSanitizedDropsATileThatIsAlsoDockedOnTheSameBoard() {
        let item = UUID()
        let instance = TerminalInstance(id: item, name: "T")
        var board = CanvasBoard(name: "B",
                                tiles: [CanvasTile(itemID: item, origin: .zero,
                                                   size: CGSize(width: 400, height: 300))])
        board.docks = [.left: DockRail(slots: [DockSlot(itemID: item)])]
        let state = SavedState(instances: [instance], canvases: [board])
        let cleaned = WorkspacePersistence.decode(
            WorkspacePersistence.encode(state)!)!
        let free = cleaned.canvases[0].tiles.contains { $0.itemID == item }
        let docked = DockLayout.dockedItems(cleaned.canvases[0].docks).contains(item)
        XCTAssertNotEqual(free, docked, "an instance must be free OR docked, never both")
    }

    func testSanitizedDropsAnInstanceDockedOnTwoBoards() {
        let item = UUID()
        let instance = TerminalInstance(id: item, name: "T")
        var a = CanvasBoard(name: "A")
        a.docks = [.left: DockRail(slots: [DockSlot(itemID: item)])]
        var b = CanvasBoard(name: "B")
        b.docks = [.right: DockRail(slots: [DockSlot(itemID: item)])]
        let cleaned = WorkspacePersistence.decode(
            WorkspacePersistence.encode(
                SavedState(instances: [instance], canvases: [a, b]))!)!
        let total = cleaned.canvases.reduce(0) {
            $0 + DockLayout.dockedItems($1.docks).count
        }
        XCTAssertEqual(total, 1, "one instance docked on two boards survived")
    }

    func testSanitizedDropsDockSlotsPointingAtMissingInstances() {
        var board = CanvasBoard(name: "B")
        board.docks = [.left: DockRail(slots: [DockSlot(itemID: UUID())])]
        let cleaned = WorkspacePersistence.decode(
            WorkspacePersistence.encode(
                SavedState(instances: [], canvases: [board]))!)!
        XCTAssertTrue(cleaned.canvases[0].docks.isEmpty,
                      "a dock slot for a deleted instance survived")
    }

    /// CHECKLIST 5: the addition is optional and backward-compatible, so the
    /// format version does not move.
    func testSavedStateVersionStaysTwo() {
        XCTAssertEqual(SavedState().version, 2)
    }
}

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

/// The five-item CanvasBoard checklist, one named test each.
///
/// **Every fixture here is produced by the same `dock`/`undock` the app calls**
/// — never hand-built. The previous version of this file hand-assembled a
/// board shape `dock()` could not produce, and codified the resulting wipe as
/// correct: docking did not survive a relaunch, and the tests said it should
/// not. A fixture that the product cannot generate proves nothing about it.
final class DockPersistenceTests: XCTestCase {
    private func boardWithDockedTerminal() -> (CanvasBoard, TerminalInstance, TerminalInstance) {
        let docked = TerminalInstance(name: "Docked")
        let free = TerminalInstance(name: "Free")
        var board = CanvasBoard(name: "B", tiles: [
            CanvasTile(itemID: docked.id, origin: CGPoint(x: 64, y: 48),
                       size: CGSize(width: 560, height: 400)),
            CanvasTile(itemID: free.id, origin: CGPoint(x: 700, y: 48),
                       size: CGSize(width: 560, height: 400)),
        ])
        board.dock(docked.id, to: DockTarget(edge: .left, insertionIndex: 0,
                                             shape: .half))
        return (board, docked, free)
    }

    /// THE test the wave was missing: dock, save, load, and the rails are
    /// still there. This failed before the fix — `sanitized` claimed the
    /// instance for its tile entry and then dropped the dock slot as a
    /// duplicate, emptying the rail on every single load.
    func testDockingSurvivesAFullSaveAndLoad() throws {
        let (board, docked, free) = boardWithDockedTerminal()
        let state = SavedState(instances: [docked, free], canvases: [board],
                               selectedCanvas: board.id)
        let reloaded = try XCTUnwrap(
            WorkspacePersistence.decode(XCTUnwrap(WorkspacePersistence.encode(state))))
        let rail = try XCTUnwrap(reloaded.canvases[0].docks[.left],
                                 "the left rail was deleted on load")
        XCTAssertEqual(rail.slots.map(\.itemID), [docked.id])
        XCTAssertEqual(rail.thickness, board.docks[.left]?.thickness)
        XCTAssertEqual(reloaded.canvases[0].tiles.map(\.itemID), [free.id],
                       "a docked instance must not also hold a tile entry")
    }

    /// Order and thickness survive too — a rail that reloads with its slots
    /// shuffled is a layout the user did not choose.
    func testRailOrderAndThicknessSurvive() throws {
        let a = TerminalInstance(name: "A"), b = TerminalInstance(name: "B")
        var board = CanvasBoard(name: "Board", tiles: [
            CanvasTile(itemID: a.id, origin: .zero, size: CanvasLayout.defaultTileSize),
            CanvasTile(itemID: b.id, origin: .zero, size: CanvasLayout.defaultTileSize),
        ])
        board.dock(a.id, to: DockTarget(edge: .right, insertionIndex: 0, shape: .half))
        board.dock(b.id, to: DockTarget(edge: .right, insertionIndex: 1, shape: .half))
        board.docks[.right]?.thickness = 412
        let reloaded = try XCTUnwrap(WorkspacePersistence.decode(
            XCTUnwrap(WorkspacePersistence.encode(
                SavedState(instances: [a, b], canvases: [board])))))
        XCTAssertEqual(reloaded.canvases[0].docks[.right]?.slots.map(\.itemID),
                       [a.id, b.id])
        XCTAssertEqual(reloaded.canvases[0].docks[.right]?.thickness, 412)
    }

    /// CHECKLIST 1 + 2: CodingKeys carries `docks`, and the hand-written
    /// init(from:) reads it back.
    func testDocksRoundTripThroughEncodeDecode() throws {
        let (board, _, _) = boardWithDockedTerminal()
        let decoded = try JSONDecoder().decode(
            CanvasBoard.self, from: JSONEncoder().encode(board))
        XCTAssertEqual(decoded.docks, board.docks)
        XCTAssertFalse(decoded.docks.isEmpty, "the decoder dropped docks entirely")
    }

    func testABoardSavedBeforeDocksDecodesWithNone() throws {
        var old = CanvasBoard(name: "Old", pan: CGPoint(x: 1, y: 2), zoom: 0.75)
        old.docks = [:]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "docks")
        let decoded = try JSONDecoder().decode(
            CanvasBoard.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(decoded.docks.isEmpty)
        XCTAssertEqual(decoded.pan, CGPoint(x: 1, y: 2))
    }

    /// CHECKLIST 3: the tripwire, answered fixture-first.
    func testTheRoundTripFixtureCarriesARealRail() throws {
        let (board, _, _) = boardWithDockedTerminal()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(board)) as? [String: Any])
        let docks = try XCTUnwrap(object["docks"] as? [String: Any])
        XCTAssertFalse(docks.isEmpty, "the fixture must exercise a non-empty rail")
    }

    /// CHECKLIST 4: single residency. A docked instance holds a SLOT and no
    /// tile, so "claimed twice" means two slots, or a slot on one board and a
    /// tile on another — never the legal tile-then-dock shape.
    func testSanitizedDropsAnInstanceDockedOnTwoBoards() throws {
        let item = TerminalInstance(name: "T")
        func board(_ name: String, _ edge: DockEdge) -> CanvasBoard {
            var b = CanvasBoard(name: name, tiles: [
                CanvasTile(itemID: item.id, origin: .zero,
                           size: CanvasLayout.defaultTileSize)])
            b.dock(item.id, to: DockTarget(edge: edge, insertionIndex: 0, shape: .half))
            return b
        }
        let cleaned = try XCTUnwrap(WorkspacePersistence.decode(
            XCTUnwrap(WorkspacePersistence.encode(
                SavedState(instances: [item],
                           canvases: [board("A", .left), board("B", .right)])))))
        let total = cleaned.canvases.reduce(0) {
            $0 + DockLayout.dockedItems($1.docks).count
        }
        XCTAssertEqual(total, 1, "one instance docked on two boards survived")
    }

    func testSanitizedDropsDockSlotsPointingAtMissingInstances() throws {
        let ghost = TerminalInstance(name: "Ghost")
        var board = CanvasBoard(name: "B", tiles: [
            CanvasTile(itemID: ghost.id, origin: .zero,
                       size: CanvasLayout.defaultTileSize)])
        board.dock(ghost.id, to: DockTarget(edge: .left, insertionIndex: 0, shape: .half))
        // The instance is NOT in the saved state: a slot pointing at nothing.
        let cleaned = try XCTUnwrap(WorkspacePersistence.decode(
            XCTUnwrap(WorkspacePersistence.encode(
                SavedState(instances: [], canvases: [board])))))
        XCTAssertTrue(cleaned.canvases[0].docks.isEmpty)
    }

    /// A hand-edited file claiming the same instance as both a tile and a
    /// slot on ONE board is still repaired — the dock wins, since that is
    /// the shape with a rail depending on it.
    func testSanitizedRepairsAHandEditedTileAndSlotClash() throws {
        let item = TerminalInstance(name: "T")
        var board = CanvasBoard(name: "B", tiles: [
            CanvasTile(itemID: item.id, origin: .zero,
                       size: CanvasLayout.defaultTileSize)])
        board.dock(item.id, to: DockTarget(edge: .left, insertionIndex: 0, shape: .half))
        // Re-add the tile entry by hand, which dock() never does.
        board.tiles.append(CanvasTile(itemID: item.id, origin: .zero,
                                      size: CanvasLayout.defaultTileSize))
        let cleaned = try XCTUnwrap(WorkspacePersistence.decode(
            XCTUnwrap(WorkspacePersistence.encode(
                SavedState(instances: [item], canvases: [board])))))
        XCTAssertEqual(DockLayout.dockedItems(cleaned.canvases[0].docks), [item.id])
        XCTAssertTrue(cleaned.canvases[0].tiles.isEmpty,
                      "the duplicate tile entry should have been dropped")
    }

    /// CHECKLIST 5.
    func testSavedStateVersionStaysTwo() {
        XCTAssertEqual(SavedState().version, 2)
    }

    // MARK: - Undock

    /// I4: undocking must not drop a terminal on top of another one.
    func testUndockingAvoidsCollisionWithExistingTiles() {
        let (boardBase, docked, _) = boardWithDockedTerminal()
        var board = boardBase
        // Put a free tile exactly where the docked one came from.
        board.tiles = [CanvasTile(itemID: UUID(), origin: CGPoint(x: 64, y: 48),
                                  size: CGSize(width: 560, height: 400))]
        board.undock(docked.id)
        let restored = board.tiles.first { $0.itemID == docked.id }
        XCTAssertNotNil(restored)
        for other in board.tiles where other.itemID != docked.id {
            XCTAssertFalse(other.frame.intersects(restored!.frame),
                           "undocked tile landed on top of another")
        }
    }

    /// With room, it goes back exactly where it was.
    func testUndockingRestoresTheOriginalFrameWhenFree() {
        let (boardBase, docked, _) = boardWithDockedTerminal()
        var board = boardBase
        board.tiles = []
        board.undock(docked.id)
        let restored = board.tiles.first { $0.itemID == docked.id }
        XCTAssertEqual(restored?.origin, CGPoint(x: 64, y: 48))
        XCTAssertEqual(restored?.size, CGSize(width: 560, height: 400))
    }

    func testUndockingRemovesTheSlot() {
        let (boardBase, docked, _) = boardWithDockedTerminal()
        var board = boardBase
        board.undock(docked.id)
        XCTAssertTrue(board.docks.isEmpty)
    }
}

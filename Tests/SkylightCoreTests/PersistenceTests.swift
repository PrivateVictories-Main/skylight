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
        let board = CanvasBoard(
            id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            name: "Work",
            tiles: [CanvasTile(itemID: instance.id, origin: CGPoint(x: 64, y: 48),
                               size: CGSize(width: 560, height: 400))],
            pan: CGPoint(x: -120, y: 40),
            zoom: 0.5)
        let state = SavedState(instances: [instance], canvases: [board],
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

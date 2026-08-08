import XCTest
import SkylightCore

final class PersistenceTests: XCTestCase {
    func testV2RoundTrip() throws {
        let instance = TerminalInstance(
            name: "Claude Code",
            spec: TerminalSpec(harness: "claude", arguments: ["--model", "opus"],
                               workingDirectory: "/tmp"))
        let board = CanvasBoard(
            name: "Work",
            tiles: [CanvasTile(itemID: instance.id, origin: CGPoint(x: 64, y: 48),
                               size: CGSize(width: 560, height: 400))],
            pan: CGPoint(x: -120, y: 40))
        let state = SavedState(instances: [instance], canvases: [board],
                               selectedCanvas: board.id)
        let data = try XCTUnwrap(WorkspacePersistence.encode(state))
        XCTAssertEqual(WorkspacePersistence.decode(data), state)
    }

    func testBoardPanDefaultsToZeroWhenAbsent() throws {
        // A v2 board saved before `pan` existed must still decode.
        let json = """
        {"version":2,"instances":[],"canvases":[
          {"id":"44444444-4444-4444-4444-444444444444","name":"Old","tiles":[]}
        ]}
        """
        let state = try XCTUnwrap(WorkspacePersistence.decode(Data(json.utf8)))
        XCTAssertEqual(state.canvases.first?.pan, .zero)
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

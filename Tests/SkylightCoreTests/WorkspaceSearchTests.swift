import XCTest
import SkylightCore

final class WorkspaceSearchTests: XCTestCase {
    private func item(_ title: String, _ detail: String = "") -> WorkspaceSearch.Item {
        .init(id: UUID(), kind: .terminal, title: title, detail: detail)
    }

    func testEmptyQueryPreservesWorkspaceOrder() {
        let items = [item("Zulu"), item("Alpha")]
        XCTAssertEqual(WorkspaceSearch.results(for: " \n ", in: items), items)
    }

    func testNameMatchesOutrankMetadataWithStableTies() {
        let metadata = item("Server", "Codex")
        let substring = item("My Codex")
        let prefix = item("Codex client")
        let exact = item("Codex")
        let secondPrefix = item("Codex API")
        XCTAssertEqual(WorkspaceSearch.results(for: "codex", in:
            [metadata, substring, prefix, exact, secondPrefix]),
            [exact, prefix, secondPrefix, substring, metadata])
    }

    func testWordsCanMatchAcrossNameAgentAndDirectory() {
        let target = item("API", "Claude Code · Backend · /projects/skylight")
        XCTAssertEqual(WorkspaceSearch.results(for: "claude   api skylight", in: [target]), [target])
        XCTAssertTrue(WorkspaceSearch.results(for: "claude missing", in: [target]).isEmpty)
    }

    func testCaseAndAccentsDoNotPreventMatches() {
        let target = item("Résumé", "Terminal")
        XCTAssertEqual(WorkspaceSearch.results(for: "RESUME", in: [target]), [target])
    }

    func testSameNamedSessionsRemainDistinct() {
        let items = [item("Shell"), item("Shell")]
        XCTAssertEqual(WorkspaceSearch.results(for: "shell", in: items), items)
    }
}

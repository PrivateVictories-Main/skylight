import { describe, it, expect } from "vitest";
import {
  parseArguments,
  search,
  searchItems,
  residentIDs,
  type Workspace,
} from "../src/model";
import fixture from "../../shared/fixtures/workspace-v2.json";

describe("workspace compatibility", () => {
  it("includes dock residents without replacing their stored geometry", () => {
    const workspace = structuredClone(fixture) as unknown as Workspace;
    const original = JSON.stringify(workspace);
    expect(residentIDs(workspace.canvases[0])).toHaveLength(2);
    expect(
      searchItems(workspace, []).filter((i) => i.kind === "terminal"),
    ).toHaveLength(2);
    expect(JSON.stringify(workspace)).toBe(original);
  });
  it("ranks exact canvas names ahead of sessions on that canvas", () => {
    const items = searchItems(fixture as unknown as Workspace, []);
    expect(search("Development", items)[0].kind).toBe("canvas");
    expect(search("codex assistant", items)[0].name).toBe("Assistant");
    expect(search("unmatched", items)).toEqual([]);
  });
  it("matches accents and preserves stable order for equal names", () => {
    const items = [
      { id: "a", kind: "terminal" as const, name: "Résumé", detail: "" },
      { id: "b", kind: "terminal" as const, name: "Résumé", detail: "" },
    ];
    expect(search("RESUME", items)).toEqual(items);
  });
  it("finds launch presets without indexing arguments or replacing active sessions", () => {
    const workspace = structuredClone(fixture) as unknown as Workspace;
    workspace.launchPresets = [
      {
        id: "preset",
        name: "Assistant",
        spec: {
          harness: "codex",
          arguments: ["PRIVATE_ARGUMENT"],
          workingDirectory: "/projects/api",
        },
      },
    ];
    const items = searchItems(workspace, []);
    expect(search("Assistant", items).map((i) => i.kind)).toEqual([
      "terminal",
      "preset",
    ]);
    expect(search("launch codex api", items).map((i) => i.id)).toEqual([
      "preset",
    ]);
    expect(search("PRIVATE_ARGUMENT", items)).toEqual([]);
  });
});
describe("literal argument grouping", () => {
  it("preserves quoted paths, empty arguments and Windows paths", () => {
    expect(
      parseArguments(`--folder "C:\\work files\\project" '' 'two words'`),
    ).toEqual(["--folder", "C:\\work files\\project", "", "two words"]);
  });
  it("treats shell substitutions as ordinary argument text", () => {
    expect(parseArguments(`'$(example)' ';'`)).toEqual(["$(example)", ";"]);
  });
  it("refuses an unterminated quote instead of launching a different command", () => {
    expect(() => parseArguments('"unfinished')).toThrow("Close the quote");
  });
});

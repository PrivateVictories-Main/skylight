export interface Spec {
  shellPath?: string | null;
  harness?: string | null;
  arguments: string[];
  workingDirectory?: string | null;
  [key: string]: unknown;
}
export interface Instance {
  id: string;
  name: string;
  spec: Spec;
  [key: string]: unknown;
}
export interface Tile {
  id: string;
  itemID: string;
  origin: [number, number];
  size: [number, number];
  [key: string]: unknown;
}
export interface Canvas {
  id: string;
  name: string;
  tiles: Tile[];
  pan: [number, number];
  zoom: number;
  docks: Record<
    string,
    { slots: { itemID: string }[]; [key: string]: unknown }
  >;
  [key: string]: unknown;
}
export interface Workspace {
  launchPresets?: Instance[];
  version: number;
  instances: Instance[];
  canvases: Canvas[];
  selectedInstance?: string | null;
  selectedCanvas?: string | null;
  [key: string]: unknown;
}
export interface Provider {
  id: string;
  name: string;
  executable: string | null;
}
export interface Bootstrap {
  workspace: Workspace;
  providers: Provider[];
  defaultShell: string;
  home: string;
  platform: string;
}
export interface SearchItem {
  id: string;
  kind: "terminal" | "canvas";
  name: string;
  detail: string;
}
export function residentIDs(board: Canvas): string[] {
  return [
    ...board.tiles.map((t) => t.itemID),
    ...Object.values(board.docks).flatMap((r) => r.slots.map((s) => s.itemID)),
  ];
}
export function boardFor(workspace: Workspace, id: string): Canvas | undefined {
  return workspace.canvases.find((b) => residentIDs(b).includes(id));
}
export function searchItems(
  workspace: Workspace,
  providers: Provider[],
): SearchItem[] {
  return [
    ...workspace.instances.map((i) => ({
      id: i.id,
      kind: "terminal" as const,
      name: i.name,
      detail: [
        providers.find((p) => p.id === i.spec.harness)?.name ??
          i.spec.harness ??
          "Terminal",
        boardFor(workspace, i.id)?.name,
        i.spec.workingDirectory,
      ]
        .filter(Boolean)
        .join(" · "),
    })),
    ...workspace.canvases.map((b) => ({
      id: b.id,
      kind: "canvas" as const,
      name: b.name,
      detail: `Canvas · ${residentIDs(b).length} sessions`,
    })),
  ];
}
const normalized = (s: string) =>
  s.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();
export function search(query: string, items: SearchItem[]): SearchItem[] {
  const q = normalized(query.trim());
  if (!q) return items;
  const tokens = q.split(/\s+/);
  return items
    .map((item, index) => {
      const title = normalized(item.name);
      const haystack = `${title} ${normalized(item.detail)}`;
      return {
        item,
        index,
        matches: tokens.every((t) => haystack.includes(t)),
        rank:
          title === q ? 0 : title.startsWith(q) ? 1 : title.includes(q) ? 2 : 3,
      };
    })
    .filter((i) => i.matches)
    .sort((a, b) => a.rank - b.rank || a.index - b.index)
    .map((i) => i.item);
}
// Argument grouping only. This never evaluates substitutions or invokes a shell.
export function parseArguments(input: string): string[] {
  const args: string[] = [];
  let value = "";
  let quote = "";
  let started = false;
  for (let index = 0; index < input.length; index++) {
    const ch = input[index];
    if (
      ch === "\\" &&
      quote !== "'" &&
      ['"', "'", "\\", " "].includes(input[index + 1])
    ) {
      value += input[++index];
      started = true;
    } else if (quote) {
      if (ch === quote) quote = "";
      else value += ch;
    } else if (ch === '"' || ch === "'") {
      quote = ch;
      started = true;
    } else if (/\s/.test(ch)) {
      if (started) {
        args.push(value);
        value = "";
        started = false;
      }
    } else {
      value += ch;
      started = true;
    }
  }
  if (quote) throw new Error("Close the quote in Arguments before continuing.");
  if (started) args.push(value);
  return args;
}
export function renameInstance(
  workspace: Workspace,
  id: string,
  name: string,
): void {
  const instance = workspace.instances.find((i) => i.id === id);
  if (instance) instance.name = name.trim() || "Terminal";
}

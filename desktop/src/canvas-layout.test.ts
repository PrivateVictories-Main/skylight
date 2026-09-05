import { describe, expect, it } from "vitest";
import {
  arrangeTiles,
  fitToView,
  magnetSnap,
  normalizeZoom,
  snapPoint,
  snapSize,
  zoomAround,
  type Frame,
  type PositionedTile,
} from "./canvas-layout";

const frame = (x: number, y: number, width = 560, height = 400): Frame => ({
  origin: [x, y],
  size: [width, height],
});
const overlaps = (a: Frame, b: Frame) =>
  a.origin[0] < b.origin[0] + b.size[0] &&
  b.origin[0] < a.origin[0] + a.size[0] &&
  a.origin[1] < b.origin[1] + b.size[1] &&
  b.origin[1] < a.origin[1] + a.size[1];

describe("native canvas geometry parity", () => {
  it("matches Swift half-away-from-zero grid rounding on either side of the origin", () => {
    expect(snapPoint([40, -40])).toEqual([48, -48]);
    expect(snapPoint([7.9, -7.9])).toEqual([0, 0]);
    expect(snapPoint([8, -8])).toEqual([16, -16]);
    expect(snapSize([10, 10])).toEqual([320, 220]);
    expect(snapSize([568, 408])).toEqual([576, 416]);
  });

  it("aligns or abuts local neighbor edges, preferring magnets to the grid", () => {
    const neighbor = frame(96, 320);
    expect(magnetSnap(frame(104, 40), [neighbor])).toEqual([96, 48]);
    expect(magnetSnap(frame(660, 320), [neighbor])).toEqual([656, 320]);
    expect(magnetSnap(frame(96, 725), [neighbor])).toEqual([96, 720]);
  });

  it("chooses the closest candidate independently on each axis", () => {
    expect(
      magnetSnap(frame(106, 106, 100, 100), [
        frame(96, 96, 100, 100),
        frame(112, 0, 100, 100),
      ]),
    ).toEqual([112, 100]);
  });

  it("does not catch on far-away tiles or candidates outside the native threshold", () => {
    expect(magnetSnap(frame(104, 40), [frame(96, 1500)])).toEqual([112, 48]);
    expect(magnetSnap(frame(104, 40), [frame(96, 520)])[0]).toBe(96);
    expect(magnetSnap(frame(104, 40), [frame(96, 536)])[0]).toBe(112);
    expect(magnetSnap(frame(108, 40), [frame(96, 320)])[0]).toBe(112);
  });

  it("preserves native reading order, sizes, metadata and untouched input when arranging", () => {
    const tiles = Array.from({ length: 7 }, (_, index) => ({
      id: String(index),
      itemID: `terminal-${index}`,
      origin: [(index * 130) % 700, (index * 210) % 900] as [number, number],
      size: [400 + (index % 3) * 80, 280 + (index % 2) * 120] as [
        number,
        number,
      ],
    }));
    const original = structuredClone(tiles);
    const arranged = arrangeTiles(tiles, [1600, 1000]);
    expect(arranged.map((tile) => tile.id)).toEqual([
      "0",
      "5",
      "6",
      "1",
      "2",
      "3",
      "4",
    ]);
    expect(tiles).toEqual(original);
    for (const tile of arranged) {
      expect(tile.size).toEqual(
        original.find((source) => source.id === tile.id)!.size,
      );
      expect(tile.itemID).toBe(`terminal-${tile.id}`);
    }
    expect(arrangeTiles([...tiles].reverse(), [1600, 1000])).toEqual(arranged);
  });

  it("keeps varied off-grid sizes separated after every snapped row", () => {
    const tiles: PositionedTile[] = Array.from({ length: 40 }, (_, index) => ({
      id: String(index),
      origin: [-index * 37, (index * 219) % 700],
      size: [320 + ((index * 43.5) % 271), 220 + ((index * 31.5) % 207)],
    }));
    for (const viewport of [
      [1600, 1000],
      [800, 1200],
      [0, 0],
    ] as const) {
      const result = arrangeTiles(tiles, viewport);
      expect(result).toHaveLength(tiles.length);
      result.forEach((tile, index) => {
        expect(tile.origin[0] % 16).toBe(0);
        expect(tile.origin[1] % 16).toBe(0);
        for (const other of result.slice(index + 1))
          expect(overlaps(tile, other)).toBe(false);
      });
    }
  });

  it("returns an empty arrangement and places a single tile at the native home origin", () => {
    expect(arrangeTiles([], [1000, 800])).toEqual([]);
    expect(
      arrangeTiles([{ id: "one", ...frame(999, -400) }], [1000, 800])[0].origin,
    ).toEqual([48, 48]);
  });

  it("fits and centers content with negative origins inside the viewport margin", () => {
    const tiles = [frame(-600, -100, 1000, 400), frame(400, 300, 1000, 400)];
    const view = fitToView(tiles, [1048, 800])!;
    expect(view.zoom).toBeCloseTo(952 / 2000);
    expect(-600 * view.zoom + view.pan[0]).toBeCloseTo(48);
    expect(1400 * view.zoom + view.pan[0]).toBeCloseTo(1000);
    expect(((-100 + 700) / 2) * view.zoom + view.pan[1]).toBeCloseTo(400);
  });

  it("never magnifies small fitted content and respects the portable readability floor", () => {
    expect(fitToView([frame(80, 40, 320, 220)], [1000, 800])).toEqual({
      zoom: 1,
      pan: [260, 250],
    });
    expect(fitToView([frame(0, 0, 100000, 100)], [1000, 800])?.zoom).toBe(0.25);
  });

  it("leaves empty or unmeasured views unchanged rather than producing invalid geometry", () => {
    expect(fitToView([], [1000, 800])).toBeNull();
    expect(fitToView([frame(0, 0)], [0, 0])).toBeNull();
    expect(fitToView([frame(0, 0)], [1000, NaN])).toBeNull();
    expect(fitToView([frame(0, 0, 0, 0)], [1000, 800])).toBeNull();
  });
});

describe("canvas zoom navigation", () => {
  it("normalizes keyboard steps and always stops exactly at interactive scale", () => {
    expect(normalizeZoom(0.8 + 0.1)).toBe(0.9);
    expect(normalizeZoom(0.99)).toBe(1);
    expect(normalizeZoom(1.01)).toBe(1);
    expect(normalizeZoom(1.05, 0.8)).toBe(1);
    expect(normalizeZoom(0.95, 1.2)).toBe(1);
    expect(normalizeZoom(1.1, 1)).toBe(1.1);
    expect(normalizeZoom(0.9, 1)).toBe(0.9);
  });

  it("clamps limits and returns a usable default for invalid input", () => {
    expect(normalizeZoom(-3)).toBe(0.25);
    expect(normalizeZoom(4)).toBe(2);
    expect(normalizeZoom(NaN)).toBe(1);
    expect(normalizeZoom(Infinity)).toBe(1);
  });

  it("holds the content under the cursor still while zooming, including the 100% stop", () => {
    const pan = [-230, 92] as const;
    const pivot = [704, 380] as const;
    for (const [current, target] of [
      [0.8, 0.9],
      [0.9, 1.1],
      [1.2, 1.1],
      [1, 2],
    ]) {
      const next = zoomAround(pan, current, target, pivot);
      for (const axis of [0, 1] as const) {
        const content = (pivot[axis] - pan[axis]) / current;
        expect(content * next.zoom + next.pan[axis]).toBeCloseTo(pivot[axis]);
      }
    }
  });
});

export type Point = readonly [number, number];
export type Size = readonly [number, number];
export interface Frame {
  origin: Point;
  size: Size;
}
export interface PositionedTile extends Frame {
  id: string;
}
export interface CanvasView {
  zoom: number;
  pan: [number, number];
}

export const CANVAS_GRID = 16;
export const MIN_TILE_SIZE: Size = [320, 220];
export const MIN_ZOOM = 0.25;
export const MAX_ZOOM = 2;

function snap(value: number): number {
  // Swift rounds half away from zero; Math.round alone disagrees at -8px.
  const rounded =
    Math.sign(value) * Math.round(Math.abs(value) / CANVAS_GRID) * CANVAS_GRID;
  return rounded === 0 ? 0 : rounded;
}

export function snapPoint(point: Point): [number, number] {
  return [snap(point[0]), snap(point[1])];
}

export function snapSize(size: Size): [number, number] {
  return [
    Math.max(MIN_TILE_SIZE[0], snap(size[0])),
    Math.max(MIN_TILE_SIZE[1], snap(size[1])),
  ];
}

/** Native edge magnets win over the grid only for nearby perpendicular spans.
 * Pass other free tiles, excluding the dragged tile and any docked sessions.
 * One linear scan; intended for gesture commits rather than every paint.
 */
export function magnetSnap(
  frame: Frame,
  others: readonly Frame[],
  threshold = 12,
  proximity = 96,
): [number, number] {
  const [x, y] = frame.origin;
  const [width, height] = frame.size;
  let nextX = snap(x);
  let nextY = snap(y);
  let bestX = threshold;
  let bestY = threshold;
  for (const other of others) {
    const [ox, oy] = other.origin;
    const [ow, oh] = other.size;
    if (y - proximity < oy + oh && oy - proximity < y + height) {
      for (const candidate of [ox, ox + ow - width, ox + ow, ox - width]) {
        const distance = Math.abs(x - candidate);
        if (distance < bestX) {
          bestX = distance;
          nextX = candidate;
        }
      }
    }
    if (x - proximity < ox + ow && ox - proximity < x + width) {
      for (const candidate of [oy, oy + oh - height, oy + oh, oy - height]) {
        const distance = Math.abs(y - candidate);
        if (distance < bestY) {
          bestY = distance;
          nextY = candidate;
        }
      }
    }
  }
  return [nextX, nextY];
}

/** Returns null for an empty board or unmeasured viewport; the caller keeps its view.
 * Fit never magnifies beyond 100%. Extremely large boards remain at MIN_ZOOM.
 */
export function fitToView(
  frames: readonly Frame[],
  viewport: Size,
  margin = 48,
): CanvasView | null {
  if (
    !frames.length ||
    !viewport.every(Number.isFinite) ||
    viewport[0] <= margin * 2 ||
    viewport[1] <= margin * 2
  )
    return null;
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;
  for (const { origin, size } of frames) {
    if (
      !origin.every(Number.isFinite) ||
      !size.every(Number.isFinite) ||
      size[0] <= 0 ||
      size[1] <= 0
    )
      return null;
    minX = Math.min(minX, origin[0]);
    minY = Math.min(minY, origin[1]);
    maxX = Math.max(maxX, origin[0] + size[0]);
    maxY = Math.max(maxY, origin[1] + size[1]);
  }
  const width = maxX - minX;
  const height = maxY - minY;
  // Preserve fractional fit values: rounding up could crop the fitted bounds.
  const zoom = Math.max(
    MIN_ZOOM,
    Math.min(
      1,
      (viewport[0] - margin * 2) / width,
      (viewport[1] - margin * 2) / height,
    ),
  );
  return {
    zoom,
    pan: [
      (viewport[0] - width * zoom) / 2 - minX * zoom,
      (viewport[1] - height * zoom) / 2 - minY * zoom,
    ],
  };
}

/** Native row arrangement: preserve size and metadata, sort in reading order,
 * and advance from each snapped origin so rounding cannot accumulate overlap.
 */
export function arrangeTiles<T extends PositionedTile>(
  tiles: readonly T[],
  viewport: Size,
): T[] {
  const ordered = [...tiles].sort((a, b) => {
    const row = Math.floor(a.origin[1] / 200) - Math.floor(b.origin[1] / 200);
    if (row !== 0) return row;
    const x = a.origin[0] - b.origin[0];
    if (x !== 0) return x;
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });
  let area = 0;
  let widest = 0;
  for (const tile of ordered) {
    area += tile.size[0] * tile.size[1];
    widest = Math.max(widest, tile.size[0]);
  }
  const aspect = viewport.every((value) => Number.isFinite(value) && value > 0)
    ? viewport[0] / viewport[1]
    : 1.6;
  const targetWidth = Math.max(widest, Math.sqrt(area * aspect));
  const start = 48;
  const gap = 24;
  let x = start;
  let y = start;
  let rowHeight = 0;
  return ordered.map((tile) => {
    if (x > start && x + tile.size[0] > start + targetWidth) {
      y += rowHeight + gap;
      x = start;
      rowHeight = 0;
    }
    const origin = snapPoint([x, y]);
    x = origin[0] + tile.size[0] + gap;
    rowHeight = Math.max(rowHeight, tile.size[1]);
    return { ...tile, origin, size: [...tile.size] as [number, number] };
  });
}

/** Keyboard/menu steps stop at exactly 100% when they reach or cross it. */
export function normalizeZoom(value: number, current?: number): number {
  if (!Number.isFinite(value)) return 1;
  const target =
    Math.round(Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, value)) * 100) / 100;
  if (
    Math.abs(target - 1) < 0.02 ||
    (current !== undefined &&
      Number.isFinite(current) &&
      (current - 1) * (target - 1) < 0)
  )
    return 1;
  return target;
}

/** Keep the same content point under the pointer or viewport center during zoom.
 * Only pan and zoom change; terminal dimensions stay in unscaled canvas space.
 */
export function zoomAround(
  pan: Point,
  current: number,
  target: number,
  pivot: Point,
): CanvasView {
  const safeCurrent = Number.isFinite(current) && current > 0 ? current : 1;
  const zoom = normalizeZoom(target, safeCurrent);
  const scale = zoom / safeCurrent;
  return {
    zoom,
    pan: [
      pivot[0] - (pivot[0] - pan[0]) * scale,
      pivot[1] - (pivot[1] - pan[1]) * scale,
    ],
  };
}

import type { ITerminalOptions, ITheme } from "@xterm/xterm";

export interface TerminalTheme {
  name: string;
  source: string;
  background: string;
  foreground: string;
  cursor?: string | null;
  selectionBackground?: string | null;
  palette: Record<string, string>;
  fontFamily?: string | null;
  fontSize?: number | null;
  backgroundOpacity?: number | null;
  cursorStyle?: string | null;
  cursorBlink?: boolean | null;
  paddingX?: number | null;
  paddingY?: number | null;
  skipped: string[];
}
export interface AppearanceSettings {
  version: number;
  theme: TerminalTheme | null;
  fontSize: number;
  opacity: number;
  paddingX: number;
  paddingY: number;
  backgroundImage?: string | null;
}
export interface AppearanceHistory {
  current: AppearanceSettings;
  previous: AppearanceSettings | null;
}
export const DEFAULT_APPEARANCE: AppearanceSettings = {
  version: 1,
  theme: null,
  fontSize: 14,
  opacity: 1,
  paddingX: 11,
  paddingY: 12,
};
export const BUILTIN_THEMES: TerminalTheme[] = [
  {
    name: "Skylight Dark",
    source: "bundled",
    background: "#212121",
    foreground: "#d8d8d8",
    cursor: "#d8d8d8",
    selectionBackground: "#555555",
    palette: {
      "0": "#262830",
      "1": "#ec8791",
      "2": "#a6d8ac",
      "3": "#e9cf8e",
      "4": "#9cbbf3",
      "5": "#c6a3ed",
      "6": "#9cdad8",
      "7": "#e2e4e9",
      "8": "#747780",
      "9": "#f49ba3",
      "10": "#b8e6bd",
      "11": "#f3dfa8",
      "12": "#b2ccfa",
      "13": "#d5baf5",
      "14": "#b1e7e6",
      "15": "#ffffff",
    },
    skipped: [],
  },
  {
    name: "Skylight Light",
    source: "bundled",
    background: "#faf9f6",
    foreground: "#292c33",
    cursor: "#292c33",
    selectionBackground: "#c8daf2",
    palette: {
      "0": "#292c33",
      "1": "#b33a48",
      "2": "#28733a",
      "3": "#80621b",
      "4": "#275b9f",
      "5": "#7951a6",
      "6": "#247780",
      "7": "#afb1b5",
      "8": "#686c76",
      "9": "#c44856",
      "10": "#328447",
      "11": "#917123",
      "12": "#386cb0",
      "13": "#8a62b7",
      "14": "#358891",
      "15": "#e4e5e7",
    },
    skipped: [],
  },
];
export function settingsForTheme(
  current: AppearanceSettings,
  theme: TerminalTheme,
): AppearanceSettings {
  return {
    ...structuredClone(current),
    theme: structuredClone(theme),
    fontSize: theme.fontSize ?? current.fontSize,
    opacity: theme.backgroundOpacity ?? current.opacity,
    paddingX: theme.paddingX ?? current.paddingX,
    paddingY: theme.paddingY ?? current.paddingY,
  };
}
const ansiNames = [
  "black",
  "red",
  "green",
  "yellow",
  "blue",
  "magenta",
  "cyan",
  "white",
  "brightBlack",
  "brightRed",
  "brightGreen",
  "brightYellow",
  "brightBlue",
  "brightMagenta",
  "brightCyan",
  "brightWhite",
] as const;
export function alphaColor(hex: string, opacity: number): string {
  return `rgba(${parseInt(hex.slice(1, 3), 16)}, ${parseInt(hex.slice(3, 5), 16)}, ${parseInt(hex.slice(5, 7), 16)}, ${opacity})`;
}
export function isLightTheme(theme: TerminalTheme): boolean {
  const channels = [1, 3, 5].map((i) =>
    parseInt(theme.background.slice(i, i + 2), 16),
  );
  return (
    channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722 > 150
  );
}
export function terminalOptions(
  settings: AppearanceSettings,
): Partial<ITerminalOptions> {
  const theme = settings.theme ?? BUILTIN_THEMES[0];
  const fallback = BUILTIN_THEMES[isLightTheme(theme) ? 1 : 0];
  const mapped: ITheme = {
    background: alphaColor(theme.background, settings.opacity),
    foreground: theme.foreground,
    cursor: theme.cursor ?? theme.foreground,
    selectionBackground:
      theme.selectionBackground ?? fallback.selectionBackground!,
  };
  for (let i = 0; i < ansiNames.length; i++)
    mapped[ansiNames[i]] =
      theme.palette[String(i)] ?? fallback.palette[String(i)];
  return {
    theme: mapped,
    fontSize: settings.fontSize,
    fontFamily: theme.fontFamily
      ? `${JSON.stringify(theme.fontFamily)}, 'Skylight Mono', monospace`
      : "'Skylight Mono', monospace",
    cursorStyle:
      theme.cursorStyle === "bar" || theme.cursorStyle === "underline"
        ? theme.cursorStyle
        : "block",
    cursorBlink: theme.cursorBlink ?? false,
  };
}
let previousImage: string | null | undefined;
export function applyChrome(settings: AppearanceSettings): void {
  const theme = settings.theme ?? BUILTIN_THEMES[0];
  const doc = document.documentElement;
  const light = isLightTheme(theme);
  doc.dataset.appearance = light ? "light" : "dark";
  doc.style.colorScheme = light ? "light" : "dark";
  doc.style.setProperty("--panel", theme.background);
  doc.style.setProperty("--terminal-foreground", theme.foreground);
  if (settings.backgroundImage !== previousImage) {
    previousImage = settings.backgroundImage;
    doc.style.setProperty(
      "--terminal-image",
      settings.backgroundImage
        ? `url(${JSON.stringify(settings.backgroundImage)})`
        : "none",
    );
  }
}

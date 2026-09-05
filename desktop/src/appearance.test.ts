import { describe, expect, it } from "vitest";
import {
  BUILTIN_THEMES,
  DEFAULT_APPEARANCE,
  settingsForTheme,
  terminalOptions,
  isLightTheme,
} from "./appearance";

describe("live appearance mapping", () => {
  it("maps indexed bright colors correctly and resets omitted fields on next theme", () => {
    const imported = {
      ...BUILTIN_THEMES[0],
      palette: { "5": "#123456", "13": "#654321" },
      cursorStyle: "bar",
      cursorBlink: true,
      fontFamily: 'My "Local" Font',
    };
    const options = terminalOptions(
      settingsForTheme(DEFAULT_APPEARANCE, imported),
    );
    expect(options.theme?.magenta).toBe("#123456");
    expect(options.theme?.brightMagenta).toBe("#654321");
    expect(options.cursorBlink).toBe(true);
    expect(options.fontFamily).toContain('\\"Local\\"');
    expect(terminalOptions(DEFAULT_APPEARANCE).cursorBlink).toBe(false);
    expect(terminalOptions(DEFAULT_APPEARANCE).cursorStyle).toBe("block");
  });
  it("imports explicit metrics and keeps unspecified settings without mutating the saved draft", () => {
    const saved = { ...DEFAULT_APPEARANCE, fontSize: 18, paddingY: 9 };
    const theme = {
      ...BUILTIN_THEMES[1],
      fontSize: 16,
      backgroundOpacity: 0.75,
      paddingX: 20,
    };
    const next = settingsForTheme(saved, theme);
    expect(next).toMatchObject({
      fontSize: 16,
      opacity: 0.75,
      paddingX: 20,
      paddingY: 9,
    });
    expect(saved.fontSize).toBe(18);
    expect(isLightTheme(theme)).toBe(true);
    expect(terminalOptions(next).theme?.background).toBe(
      "rgba(250, 249, 246, 0.75)",
    );
  });
});

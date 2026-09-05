import {
  alphaColor,
  BUILTIN_THEMES,
  isLightTheme,
  DEFAULT_APPEARANCE,
  settingsForTheme,
  type AppearanceSettings,
  type TerminalTheme,
} from "./appearance";
import "./appearance-panel.css";

export interface AppearancePanelOptions {
  current: AppearanceSettings;
  preview(settings: AppearanceSettings): void;
  save(settings: AppearanceSettings): Promise<void>;
  cancel(): void;
  importFile(): Promise<TerminalTheme[] | null>;
  discover(): Promise<{ id: string; name: string }[]>;
  importDetected(id: string): Promise<TerminalTheme[]>;
  chooseBackground(): Promise<string | null>;
  catalog?(): Promise<TerminalTheme[]>;
}

/** A disposable draft; only Save persists it. The owner restores on any dismissal. */
export function appearancePanel(options: AppearancePanelOptions): HTMLElement {
  const saved = structuredClone(options.current);
  let draft = structuredClone(saved);
  let busy = false;
  let closed = false;
  let sampleImage: string | null | undefined;
  let selectedCatalogTheme: TerminalTheme | null = null;
  const savedKey = JSON.stringify({ ...saved, backgroundImage: null });
  const matchesSaved = () =>
    (draft.backgroundImage ?? null) === (saved.backgroundImage ?? null) &&
    JSON.stringify({ ...draft, backgroundImage: null }) === savedKey;
  const form = document.createElement("form");
  form.className = "appearance-panel";
  const fields = document.createElement("fieldset");
  fields.className = "appearance-fields";
  const make = <K extends keyof HTMLElementTagNameMap>(
    tag: K,
    text?: string,
    className?: string,
  ) => {
    const node = document.createElement(tag);
    if (text) node.textContent = text;
    if (className) node.className = className;
    return node;
  };
  const button = (text: string, action: () => void, className?: string) => {
    const node = make("button", text, className);
    node.type = "button";
    node.onclick = action;
    return node;
  };
  const labeled = (name: string, control: HTMLElement) => {
    const row = make("label");
    control.setAttribute("aria-label", name);
    row.append(make("span", name), control);
    return row;
  };
  const textInput = (placeholder?: string) => {
    const input = make("input");
    input.autocomplete = "off";
    input.spellcheck = false;
    if (placeholder) input.placeholder = placeholder;
    return input;
  };
  const selectOption = (value: string, name: string) => {
    const option = make("option", name);
    option.value = value;
    return option;
  };
  const themeKey = (theme: TerminalTheme | null) => JSON.stringify(theme);
  const themes = BUILTIN_THEMES.map((theme) => structuredClone(theme));
  if (
    saved.theme &&
    !themes.some((theme) => themeKey(theme) === themeKey(saved.theme))
  ) {
    themes.push(structuredClone(saved.theme));
  }
  const themeSelect = make("select");
  const error = make("p", undefined, "appearance-error");
  error.hidden = true;
  error.setAttribute("role", "alert");
  const status = make("p", undefined, "appearance-status hint");
  status.hidden = true;
  status.setAttribute("role", "status");
  const showError = (failure: unknown) => {
    error.textContent =
      failure instanceof Error ? failure.message : String(failure);
    error.hidden = false;
  };
  const clearError = () => {
    error.textContent = "";
    error.hidden = true;
  };
  const report = (text: string) => {
    status.textContent = text;
    status.hidden = !text;
  };
  const ensureTheme = () => {
    draft.theme ??= structuredClone(
      DEFAULT_APPEARANCE.theme ?? BUILTIN_THEMES[0],
    );
    return draft.theme;
  };
  const sample = make("div", undefined, "appearance-sample");
  sample.setAttribute("aria-label", "Theme preview");
  const sampleSurface = make("div", undefined, "appearance-sample-surface");
  sampleSurface.setAttribute("aria-hidden", "true");
  const samplePrompt = make("span", "~/project", "appearance-sample-prompt");
  const sampleCommand = make("span", "  $ your next idea");
  const sampleCursor = make("span", " ", "appearance-sample-cursor");
  const sampleSwatches = make("div", undefined, "appearance-sample-swatches");
  sampleSwatches.setAttribute("aria-hidden", "true");
  for (let index = 0; index < 8; index++) sampleSwatches.append(make("i"));
  const sampleLine = make("div", undefined, "appearance-sample-line");
  sampleLine.append(samplePrompt, sampleCommand, sampleCursor);
  sample.append(sampleSurface, sampleLine, sampleSwatches);
  const fontSize = make("input");
  fontSize.type = "range";
  fontSize.min = "6";
  fontSize.max = "32";
  fontSize.step = "1";
  const fontValue = make("output");
  const opacity = make("input");
  opacity.type = "range";
  opacity.min = "0.2";
  opacity.max = "1";
  opacity.step = "0.05";
  const opacityValue = make("output");
  const rangeRow = (
    name: string,
    input: HTMLInputElement,
    output: HTMLOutputElement,
  ) => {
    const control = make("div", undefined, "appearance-range");
    control.append(input, output);
    input.setAttribute("aria-label", name);
    const label = make("label");
    label.append(make("span", name), control);
    return label;
  };
  const color = (name: string) => {
    const input = make("input");
    input.type = "color";
    input.setAttribute("aria-label", name);
    return input;
  };
  const background = color("Background color");
  const foreground = color("Text color");
  const colors = make("div", undefined, "appearance-colors");
  colors.append(
    labeled("Background color", background),
    labeled("Text color", foreground),
  );
  const fontFamily = textInput("Skylight Mono");
  const cursorStyle = make("select");
  cursorStyle.append(
    selectOption("", "Default"),
    selectOption("block", "Block"),
    selectOption("bar", "Bar"),
    selectOption("underline", "Underline"),
  );
  const cursorBlink = make("input");
  cursorBlink.type = "checkbox";
  const blinkLabel = labeled("Blink cursor", cursorBlink);
  blinkLabel.className = "appearance-checkbox";
  const numberInput = () => {
    const input = make("input");
    input.type = "number";
    input.min = "0";
    input.max = "80";
    input.step = "1";
    return input;
  };
  const paddingX = numberInput();
  const paddingY = numberInput();
  const padding = make("div", undefined, "appearance-columns");
  padding.append(
    labeled("Horizontal padding", paddingX),
    labeled("Vertical padding", paddingY),
  );
  const advanced = make("details", undefined, "appearance-details");
  advanced.append(make("summary", "More customization"));
  advanced.append(
    labeled("Font family", fontFamily),
    make(
      "p",
      "Use a font installed on this computer. Skylight Mono is always available.",
      "hint",
    ),
    labeled("Cursor shape", cursorStyle),
    blinkLabel,
    padding,
  );
  const ansi = make("details", undefined, "appearance-details appearance-ansi");
  ansi.append(make("summary", "Terminal palette"));
  const palette = make("div", undefined, "appearance-palette");
  const names = [
    "Black",
    "Red",
    "Green",
    "Yellow",
    "Blue",
    "Magenta",
    "Cyan",
    "White",
  ];
  const paletteInputs = Array.from({ length: 16 }, (_, index) => {
    const name = `${index >= 8 ? "Bright " : ""}${names[index % 8]}`;
    const input = color(`ANSI ${index}: ${name}`);
    palette.append(labeled(name, input));
    input.oninput = () => {
      ensureTheme().palette[String(index)] = input.value;
      changed();
    };
    return input;
  });
  ansi.append(palette);
  advanced.append(ansi);
  const skipped = make(
    "details",
    undefined,
    "appearance-details appearance-skipped",
  );
  const skippedSummary = make("summary");
  const skippedList = make("ul");
  skipped.append(
    skippedSummary,
    make(
      "p",
      "Only supported appearance settings are imported. Commands and other terminal behavior stay unchanged.",
      "hint",
    ),
    skippedList,
  );
  const backgroundRow = make("div", undefined, "appearance-background");
  const backgroundName = make("span", "No background image", "hint");
  const chooseBackground = button("Choose image…", () => {
    void operation(async () => {
      const image = await options.chooseBackground();
      if (!available() || image === null) return;
      await validateBackgroundImage(image);
      if (!available()) return;
      draft.backgroundImage = image;
      if (draft.opacity === 1) draft.opacity = 0.85;
      refresh();
      changed();
    });
  });
  const removeBackground = button(
    "Remove",
    () => {
      draft.backgroundImage = null;
      refresh();
      changed();
    },
    "subtle",
  );
  backgroundRow.append(chooseBackground, removeBackground, backgroundName);
  const backgroundLabel = make(
    "div",
    "Background image",
    "appearance-section-label",
  );
  const imports = make("div", undefined, "appearance-imports");
  const importButton = button("Import theme file…", () => {
    void operation(async () => {
      const imported = await options.importFile();
      if (!available() || imported === null) return;
      importThemes(imported);
    });
  });
  imports.append(importButton);
  const detected = make("div", undefined, "appearance-detected");
  detected.hidden = true;
  const importHint = make(
    "p",
    "Bring in colors and supported appearance settings from another terminal.",
    "hint",
  );
  const catalog = make(
    "details",
    undefined,
    "appearance-details appearance-catalog",
  );
  catalog.hidden = !options.catalog;
  catalog.append(make("summary", "Browse themes"));
  const catalogSearch = textInput("Search themes");
  catalogSearch.type = "search";
  catalogSearch.disabled = true;
  const catalogResults = make("select");
  catalogResults.size = 6;
  catalogResults.disabled = true;
  catalogResults.setAttribute("aria-label", "Bundled themes");
  const catalogStatus = make("p", undefined, "hint");
  catalogStatus.setAttribute("role", "status");
  const retryCatalog = button("Try again", () => {
    void loadCatalog();
  });
  retryCatalog.hidden = true;
  let catalogThemes: TerminalTheme[] | undefined;
  let catalogLoading = false;
  catalog.append(
    labeled("Search themes", catalogSearch),
    catalogResults,
    catalogStatus,
    retryCatalog,
  );
  function renderCatalog() {
    const query = catalogSearch.value.trim().toLocaleLowerCase();
    const matching = (catalogThemes ?? [])
      .map((theme, index) => ({ theme, index }))
      .filter(({ theme }) => theme.name.toLocaleLowerCase().includes(query));
    const visible = matching.slice(0, 10);
    catalogResults.replaceChildren(
      ...visible.map(({ theme, index }) =>
        selectOption(String(index), theme.name),
      ),
    );
    catalogResults.selectedIndex = -1;
    catalogResults.disabled = !visible.length;
    catalogStatus.textContent = !matching.length
      ? "No themes match. Try a different name."
      : matching.length > 10
        ? `Showing 10 of ${matching.length} themes. Type a name to narrow the list.`
        : `${matching.length} ${matching.length === 1 ? "theme" : "themes"}. Select one to preview.`;
  }
  async function loadCatalog() {
    if (!options.catalog || catalogLoading || !available()) return;
    catalogLoading = true;
    retryCatalog.hidden = true;
    catalogStatus.textContent = "Loading themes…";
    catalog.setAttribute("aria-busy", "true");
    try {
      const loaded = await options.catalog();
      if (!available()) return;
      catalogThemes = loaded;
      catalogSearch.disabled = false;
      catalogSearch.placeholder = `Search ${loaded.length} themes`;
      renderCatalog();
    } catch {
      if (!available()) return;
      catalogStatus.textContent =
        "The theme collection could not be loaded. Try again.";
      retryCatalog.hidden = false;
    } finally {
      catalogLoading = false;
      if (available()) catalog.setAttribute("aria-busy", "false");
    }
  }
  catalog.ontoggle = () => {
    if (catalog.open && !catalogThemes) void loadCatalog();
  };
  catalogSearch.oninput = renderCatalog;
  catalogSearch.onkeydown = (event) => {
    if (event.key === "ArrowDown" && !catalogResults.disabled) {
      event.preventDefault();
      catalogResults.focus();
    }
  };
  catalogResults.onchange = () => {
    if (busy || closed || catalogResults.selectedIndex < 0) return;
    const theme = catalogThemes?.[Number(catalogResults.value)];
    if (!theme) return;
    selectedCatalogTheme = structuredClone(theme);
    draft = settingsForTheme(draft, theme);
    report(`Previewing ${theme.name}. Save to keep it.`);
    refresh();
    changed();
  };
  const saveButton = make("button", "Save appearance", "primary");
  saveButton.type = "submit";
  const cancelButton = button("Cancel", () => {
    closed = true;
    options.cancel();
  });
  const revert = button(
    "Revert to saved",
    () => {
      draft = structuredClone(saved);
      clearError();
      report("");
      refresh();
      changed();
    },
    "subtle",
  );
  const reset = button(
    "Reset defaults",
    () => {
      draft = structuredClone(DEFAULT_APPEARANCE);
      clearError();
      report("");
      refresh();
      changed();
    },
    "subtle",
  );
  const resetActions = make("div", undefined, "appearance-reset-actions");
  resetActions.append(revert, reset);
  const actions = make("div", undefined, "dialog-actions");
  actions.append(cancelButton, saveButton);
  fields.append(
    sample,
    labeled("Theme", themeSelect),
    catalog,
    imports,
    detected,
    importHint,
    status,
    rangeRow("Font size", fontSize, fontValue),
    rangeRow("Background opacity", opacity, opacityValue),
    colors,
    backgroundLabel,
    backgroundRow,
    make(
      "p",
      "Opacity reveals the image or Skylight surface behind your terminal.",
      "hint",
    ),
    advanced,
    skipped,
    resetActions,
  );
  form.append(fields, error, actions);

  function available() {
    return !closed && form.isConnected;
  }
  function setBusy(value: boolean, saving = false) {
    busy = value;
    fields.disabled = value;
    saveButton.disabled = value;
    cancelButton.disabled = value && saving;
    form.setAttribute("aria-busy", String(value));
  }
  async function operation(action: () => Promise<void>) {
    if (busy || closed) return;
    clearError();
    setBusy(true);
    try {
      await action();
    } catch (failure) {
      if (available()) showError(failure);
    } finally {
      if (available()) setBusy(false);
    }
  }
  function themeOptions() {
    themeSelect.replaceChildren(selectOption("", "Default"));
    themes.forEach((theme, index) => {
      themeSelect.append(selectOption(String(index), theme.name));
    });
    if (!draft.theme) {
      themeSelect.value = "";
      return;
    }
    const index = themes.findIndex(
      (theme) => themeKey(theme) === themeKey(draft.theme),
    );
    if (index === -1) {
      const isCatalog =
        selectedCatalogTheme &&
        themeKey(draft.theme) === themeKey(selectedCatalogTheme);
      themeSelect.append(
        selectOption(
          isCatalog ? "catalog" : "custom",
          isCatalog ? draft.theme.name : `${draft.theme.name} · Custom`,
        ),
      );
      themeSelect.value = isCatalog ? "catalog" : "custom";
    } else {
      themeSelect.value = String(index);
    }
  }
  function paintSample() {
    const theme = draft.theme ?? DEFAULT_APPEARANCE.theme ?? BUILTIN_THEMES[0];
    const fallback = BUILTIN_THEMES[isLightTheme(theme) ? 1 : 0];
    const overlay = alphaColor(theme.background, draft.opacity);
    sample.style.backgroundColor = draft.backgroundImage
      ? theme.background
      : "transparent";
    sampleSurface.style.backgroundColor = overlay;
    const image = draft.backgroundImage ?? null;
    if (sampleImage !== image) {
      sample.style.backgroundImage = image
        ? `url(${JSON.stringify(image)})`
        : "none";
      sampleImage = image;
    }
    sample.style.color = theme.foreground;
    sample.style.fontSize = `${draft.fontSize}px`;
    sample.style.fontFamily = theme.fontFamily
      ? `${JSON.stringify(theme.fontFamily)}, "Skylight Mono", monospace`
      : '"Skylight Mono", monospace';
    samplePrompt.style.color = theme.palette["2"] ?? fallback.palette["2"];
    sampleCursor.style.backgroundColor = theme.cursor ?? theme.foreground;
    sampleCursor.dataset.shape = theme.cursorStyle ?? "block";
    for (const [index, swatch] of [...sampleSwatches.children].entries()) {
      (swatch as HTMLElement).style.backgroundColor =
        theme.palette[String(index)] ?? fallback.palette[String(index)];
    }
  }
  function changed() {
    themeOptions();
    paintSample();
    fontValue.value = `${draft.fontSize} px`;
    opacityValue.value = `${Math.round(draft.opacity * 100)}%`;
    revert.disabled = matchesSaved();
    options.preview(structuredClone(draft));
  }
  function refresh() {
    themeOptions();
    const theme = draft.theme ?? DEFAULT_APPEARANCE.theme ?? BUILTIN_THEMES[0];
    fontSize.value = String(draft.fontSize);
    fontValue.value = `${draft.fontSize} px`;
    opacity.value = String(draft.opacity);
    opacityValue.value = `${Math.round(draft.opacity * 100)}%`;
    background.value = theme.background;
    foreground.value = theme.foreground;
    fontFamily.value = theme.fontFamily ?? "";
    cursorStyle.value = theme.cursorStyle ?? "";
    cursorBlink.checked = theme.cursorBlink ?? false;
    paddingX.value = String(draft.paddingX);
    paddingY.value = String(draft.paddingY);
    const fallback = BUILTIN_THEMES[isLightTheme(theme) ? 1 : 0];
    paletteInputs.forEach((input, index) => {
      input.value =
        theme.palette[String(index)] ?? fallback.palette[String(index)];
    });
    backgroundName.textContent = draft.backgroundImage
      ? "Image selected"
      : "No image";
    removeBackground.hidden = !draft.backgroundImage;
    skipped.hidden = !theme.skipped.length;
    skippedSummary.textContent = `${theme.skipped.length} unsupported ${theme.skipped.length === 1 ? "setting" : "settings"}`;
    skippedList.replaceChildren(
      ...theme.skipped.map((setting) => make("li", setting)),
    );
    revert.disabled = matchesSaved();
    paintSample();
  }
  function importThemes(imported: TerminalTheme[]) {
    if (!imported.length) {
      report("No supported themes were found in that file.");
      return;
    }
    for (const theme of imported) {
      if (!themes.some((item) => themeKey(item) === themeKey(theme)))
        themes.push(structuredClone(theme));
    }
    draft = settingsForTheme(draft, imported[0]);
    report(
      imported.length === 1
        ? `Previewing ${imported[0].name}. Save to keep it.`
        : `Imported ${imported.length} themes. Previewing ${imported[0].name}; choose another in Theme.`,
    );
    refresh();
    changed();
  }
  themeSelect.onchange = () => {
    if (themeSelect.value === "custom" || themeSelect.value === "catalog")
      return;
    draft =
      themeSelect.value === ""
        ? { ...draft, theme: null }
        : settingsForTheme(draft, themes[Number(themeSelect.value)]);
    report("");
    refresh();
    changed();
  };
  fontSize.oninput = () => {
    draft.fontSize = Number(fontSize.value);
    changed();
  };
  opacity.oninput = () => {
    draft.opacity = Number(opacity.value);
    changed();
  };
  background.oninput = () => {
    ensureTheme().background = background.value;
    changed();
  };
  foreground.oninput = () => {
    ensureTheme().foreground = foreground.value;
    changed();
  };
  fontFamily.oninput = () => {
    ensureTheme().fontFamily = fontFamily.value.trim() || null;
    changed();
  };
  cursorStyle.onchange = () => {
    ensureTheme().cursorStyle = cursorStyle.value || null;
    changed();
  };
  cursorBlink.onchange = () => {
    ensureTheme().cursorBlink = cursorBlink.checked;
    changed();
  };
  paddingX.oninput = () => {
    if (!paddingX.value || !paddingX.validity.valid) return;
    draft.paddingX = Number(paddingX.value);
    changed();
  };
  paddingY.oninput = () => {
    if (!paddingY.value || !paddingY.validity.valid) return;
    draft.paddingY = Number(paddingY.value);
    changed();
  };
  form.onsubmit = (event) => {
    event.preventDefault();
    if (busy || closed || !form.reportValidity()) return;
    clearError();
    setBusy(true, true);
    saveButton.textContent = "Saving…";
    void options
      .save(structuredClone(draft))
      .then(() => {
        closed = true;
      })
      .catch((failure: unknown) => {
        if (!available()) return;
        showError(failure);
        setBusy(false);
        saveButton.textContent = "Save appearance";
      });
  };
  refresh();
  queueMicrotask(() => {
    if (!available()) return;
    void options
      .discover()
      .then((sources) => {
        if (!available()) return;
        detected.hidden = !sources.length;
        detected.append(make("span", "Found on this computer", "hint"));
        for (const source of sources) {
          detected.append(
            button(`Import ${source.name}`, () => {
              void operation(async () => {
                const imported = await options.importDetected(source.id);
                if (available()) importThemes(imported);
              });
            }),
          );
        }
      })
      .catch(() => {
        // File import remains available when local config discovery is unavailable.
      });
  });
  return form;
}

/** Decode managed raster data before replacing a working background. */
async function validateBackgroundImage(source: string): Promise<void> {
  if (!/^data:image\/(?:png|jpeg);base64,/.test(source)) {
    throw new Error("Choose a PNG or JPEG background image.");
  }
  const image = new Image();
  image.decoding = "async";
  try {
    image.src = source;
    try {
      await image.decode();
    } catch {
      throw new Error(
        "This image could not be opened. Choose a different PNG or JPEG file.",
      );
    }
    const width = image.naturalWidth;
    const height = image.naturalHeight;
    if (
      width <= 0 ||
      height <= 0 ||
      width > 8192 ||
      height > 8192 ||
      width * height > 33_000_000
    ) {
      throw new Error(
        "Choose an image no larger than 8,192 pixels on either side and 33 megapixels overall.",
      );
    }
  } finally {
    image.removeAttribute("src");
  }
}

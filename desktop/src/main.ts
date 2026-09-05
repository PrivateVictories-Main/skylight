import { invoke, isTauri } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { TerminalSession } from "./terminal";
import {
  boardFor,
  parseArguments,
  presetSpec,
  residentIDs,
  search,
  searchItems,
  type Bootstrap,
  type Canvas,
  type Instance,
  type SearchItem,
  type Workspace,
} from "./model";
import { showMenu, type MenuAction } from "./menu";
import { presetEditor } from "./preset-editor";
import {
  DEFAULT_APPEARANCE,
  applyChrome,
  type AppearanceHistory,
  type AppearanceSettings,
} from "./appearance";
import {
  magnetSnap,
  snapSize,
  fitToView,
  arrangeTiles,
  zoomAround,
  zoomAroundContinuous,
} from "./canvas-layout";
import "./style.css";

const root = document.querySelector<HTMLDivElement>("#app")!;
const updateWindowFocus = () =>
  root.classList.toggle("window-inactive", !document.hasFocus());
window.addEventListener("focus", updateWindowFocus);
window.addEventListener("blur", updateWindowFocus);
updateWindowFocus();
root.innerHTML = `<aside class="sidebar"><header class="sidebar-chrome"><button id="workspace-menu" class="icon-button" aria-label="Workspace menu" title="Workspace menu">…</button><span class="spacer"></span><button id="switch" class="icon-button" aria-label="Search workspace" title="Search workspace"></button><button id="sidebar-toggle" class="icon-button" aria-label="Hide sidebar" title="Hide sidebar"></button></header><nav id="sessions" aria-label="Workspace"></nav><footer><button id="new-terminal" aria-label="New Terminal">＋ New</button></footer></aside><button id="sidebar-reveal" class="icon-button" aria-label="Show sidebar" title="Show sidebar" hidden></button><main><header id="toolbar"></header><div id="content"></div><div id="notice" role="status" hidden></div></main>`;
const nav = document.querySelector<HTMLElement>("#sessions")!;
const toolbar = document.querySelector<HTMLElement>("#toolbar")!;
const content = document.querySelector<HTMLElement>("#content")!;
const notice = document.querySelector<HTMLElement>("#notice")!;
let data: Bootstrap;
let workspace: Workspace;
let selected: { kind: "terminal" | "canvas"; id: string } | undefined;
let previousBoard: string | undefined;
let modal: HTMLDialogElement | undefined;
let saving = Promise.resolve();
let lastFocusedSession: string | undefined;
let canvasRefresh: (() => void) | undefined;
let navigationSave: ReturnType<typeof setTimeout> | undefined;
let allowClose = false;
let appearanceHistory: AppearanceHistory = {
  current: structuredClone(DEFAULT_APPEARANCE),
  previous: null,
};
let activeAppearance = appearanceHistory.current;
function previewAppearance(settings: AppearanceSettings): void {
  activeAppearance = settings;
  applyChrome(settings);
  for (const session of sessions.values()) session.applyAppearance(settings);
}
let appearanceOpening = false;
async function openAppearance(): Promise<void> {
  if (appearanceOpening || modal) return;
  appearanceOpening = true;
  let panelModule;
  try {
    panelModule = await import("./appearance-panel");
  } finally {
    appearanceOpening = false;
  }
  if (modal) return;
  const { appearancePanel } = panelModule;
  const entry = structuredClone(appearanceHistory.current);
  const { dialog: dlg, body, close } = dialog("Appearance");
  let committed = false;
  dlg.addEventListener("close", () => {
    if (!committed) previewAppearance(entry);
  });
  body.append(
    appearancePanel({
      current: entry,
      preview: previewAppearance,
      cancel: close,
      save: async (settings) => {
        dlg.dataset.busy = "true";
        try {
          const next = await invoke<AppearanceHistory>("save_appearance", {
            settings,
          });
          appearanceHistory = next;
          previewAppearance(next.current);
          committed = true;
          delete dlg.dataset.busy;
          close();
        } finally {
          delete dlg.dataset.busy;
        }
      },
      importFile: () => invoke("import_theme_file"),
      discover: () => invoke("discover_themes"),
      importDetected: (id) => invoke("import_detected_theme", { id }),
      chooseBackground: () => invoke("choose_background"),
      catalog: () => invoke("bundled_themes"),
    }),
  );
  dlg.showModal();
}
async function revertAppearance(): Promise<void> {
  appearanceHistory = await invoke<AppearanceHistory>("revert_appearance");
  previewAppearance(appearanceHistory.current);
  restoreFocus();
}
let providerRefresh: Promise<void> | undefined;
const sessions = new Map<string, TerminalSession>();
const starting = new Map<string, Promise<void>>();

function element<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  text?: string,
  className?: string,
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (className) node.className = className;
  return node;
}
function button(
  text: string,
  action: () => void | Promise<void>,
  className?: string,
): HTMLButtonElement {
  const node = element("button", text, className);
  node.type = "button";
  node.onclick = () => {
    Promise.resolve(action()).catch(report);
  };
  return node;
}
function report(error: unknown): void {
  notice.replaceChildren(
    element("span", String(error)),
    button("Dismiss", () => {
      notice.hidden = true;
    }),
  );
  notice.hidden = false;
}
function persist(): Promise<void> {
  const snapshot = structuredClone(workspace);
  // Serialize disk writes; a slow earlier save cannot overwrite a newer layout.
  saving = saving
    .catch(() => {})
    .then(() => invoke("save_workspace", { workspace: snapshot }));
  void saving.catch(report);
  return saving;
}
function status(id: string): string {
  return sessions.get(id)?.state ?? "Ready to open";
}
const glyphs = {
  terminal:
    '<rect x="2.5" y="4" width="15" height="12" rx="2"/><path d="m6 8 2 2-2 2m5 0h3"/>',
  canvas:
    '<rect x="6" y="6" width="11" height="11" rx="2"/><path d="M13 4V3H3v10h1"/>',
  search: '<circle cx="8.5" cy="8.5" r="5.5"/><path d="m13 13 4 4"/>',
  sidebar:
    '<rect x="2" y="3" width="16" height="14" rx="2"/><path d="M8 3v14M4.5 6h1m-1 3h1"/>',
  expand: '<path d="M3 8V3h5M3 3l5 5m9 4v5h-5m5 0-5-5"/>',
  close: '<path d="m5 5 10 10M15 5 5 15"/>',
  plus: '<path d="M10 3v14M3 10h14"/>',
} as const;
function icon(kind: keyof typeof glyphs): HTMLElement {
  const node = element("span", undefined, "glyph");
  node.setAttribute("aria-hidden", "true");
  node.innerHTML = `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round">${glyphs[kind]}</svg>`;
  return node;
}
function menuAt(node: HTMLElement, actions: MenuAction[]): void {
  const rect = node.getBoundingClientRect();
  showMenu(actions, { x: rect.left, y: rect.bottom + 4 }, report);
}
function instanceActions(instance: Instance): MenuAction[] {
  const actions: MenuAction[] = [
    { label: "Save preset", run: () => savePreset(instance) },
    { label: "Edit launch settings", run: () => editInstance(instance) },
    { label: "Move to canvas", run: () => placeInstance(instance) },
  ];
  if (["ended", "error"].includes(status(instance.id)))
    actions.push({ label: "Restart", run: () => start(instance) });
  if (boardFor(workspace, instance.id))
    actions.push({
      label: "Remove from canvas",
      run: () => detachInstance(instance),
    });
  actions.push({ label: "Close", run: () => removeInstance(instance) });
  return actions;
}
function contextual(node: HTMLElement, actions: () => MenuAction[]): void {
  node.oncontextmenu = (event) => {
    event.preventDefault();
    event.stopPropagation();
    showMenu(actions(), { x: event.clientX, y: event.clientY }, report);
  };
  node.onkeydown = (event) => {
    if (
      event.key === "ContextMenu" ||
      (event.shiftKey && event.key === "F10")
    ) {
      event.preventDefault();
      menuAt(node, actions());
    }
  };
}
function renderNav(): void {
  nav.replaceChildren();
  const addInstance = (instance: Instance, resident = false) => {
    const wrapper = element("div", undefined, "instance-row");
    wrapper.classList.toggle("resident", resident);
    const row = button(
      "",
      () => select({ kind: "terminal", id: instance.id }),
      "session-row",
    );
    row.classList.toggle("selected", selected?.id === instance.id);
    row.setAttribute("aria-label", `${instance.name}, ${status(instance.id)}`);
    row.setAttribute("aria-current", String(selected?.id === instance.id));
    const label = element("span", undefined, "row-label");
    label.append(element("span", instance.name, "row-name"));
    const caption =
      status(instance.id) === "ended"
        ? "Session ended"
        : instance.spec.workingDirectory;
    if (caption) {
      const folder = caption.split(/[\\/]/).filter(Boolean).at(-1);
      const short =
        caption === "Session ended" || !folder || /^[A-Za-z]:$/.test(folder)
          ? caption
          : folder;
      const subtitle = element("span", short, "row-caption");
      subtitle.title = caption;
      label.append(subtitle);
    }
    row.append(icon("terminal"), label);
    const more = button(
      "…",
      () => menuAt(more, instanceActions(instance)),
      "row-more",
    );
    more.setAttribute("aria-label", `Actions for ${instance.name}`);
    more.title = "Terminal actions";
    contextual(row, () => instanceActions(instance));
    wrapper.append(row, more);
    nav.append(wrapper);
  };
  nav.append(element("h2", "TERMINALS"));
  const free = workspace.instances.filter((i) => !boardFor(workspace, i.id));
  free.forEach((instance) => addInstance(instance));
  if (!free.length)
    nav.append(
      element(
        "p",
        `${data.platform === "macos" ? "⌘T" : "Ctrl+Shift+T"} new terminal`,
        "sidebar-hint",
      ),
    );
  for (const board of workspace.canvases) {
    const row = button(
      "",
      () => select({ kind: "canvas", id: board.id }),
      "canvas-row",
    );
    row.classList.toggle("selected", selected?.id === board.id);
    row.append(
      icon("canvas"),
      element("span", board.name, "row-name"),
      element("span", String(residentIDs(board).length), "count"),
    );
    nav.append(row);
    residentIDs(board).forEach((id) => {
      const instance = workspace.instances.find((i) => i.id === id);
      if (instance) addInstance(instance, true);
    });
  }
  if (!workspace.canvases.length)
    nav.append(
      element("p", "Right-click a terminal\nto start a canvas", "sidebar-hint"),
    );
}
async function detachInstance(instance: Instance): Promise<void> {
  for (const board of workspace.canvases) {
    board.tiles = board.tiles.filter((tile) => tile.itemID !== instance.id);
    for (const rail of Object.values(board.docks))
      rail.slots = rail.slots.filter((slot) => slot.itemID !== instance.id);
  }
  select({ kind: "terminal", id: instance.id });
  await persist();
}
function select(item: { kind: "terminal" | "canvas"; id: string }): void {
  selected = item;
  if (item.kind === "terminal") {
    workspace.selectedInstance = item.id;
    workspace.selectedCanvas = null;
    previousBoard = boardFor(workspace, item.id)?.id;
  } else {
    workspace.selectedCanvas = item.id;
    workspace.selectedInstance = null;
    previousBoard = undefined;
  }
  render();
  void persist();
}
function render(): void {
  canvasRefresh = undefined;
  const board =
    selected?.kind === "canvas"
      ? workspace.canvases.find((b) => b.id === selected!.id)
      : undefined;
  const visibleIDs = new Set(
    selected?.kind === "terminal"
      ? [selected.id]
      : board
        ? board.tiles.map((tile) => tile.itemID)
        : [],
  );
  const focused = [...sessions.values()].find((session) =>
    session.element.contains(document.activeElement),
  );
  // A status update or move between visible surfaces should not rebuild the GPU
  // renderer. Release it only when the terminal actually leaves the live view.
  for (const [id, session] of sessions)
    if (!visibleIDs.has(id)) session.setVisible(false);
  renderNav();
  toolbar.replaceChildren();
  toolbar.className = "";
  content.classList.toggle("is-canvas", Boolean(board));
  delete content.dataset.sessionState;
  content.oncontextmenu = null;
  content.replaceChildren();
  if (!selected) {
    renderWelcome();
    return;
  }
  if (selected.kind === "canvas") {
    if (board) renderCanvas(board);
    else renderWelcome();
    if (board?.zoom === 1 && focused && visibleIDs.has(focused.instance.id))
      focused.terminal.focus();
    return;
  }
  const instance = workspace.instances.find((i) => i.id === selected!.id);
  if (!instance) {
    renderWelcome();
    return;
  }
  content.dataset.sessionState = status(instance.id);
  const activeSession = sessions.get(instance.id);
  if (activeSession) activeSession.element.inert = false;
  // A terminal owns its full panel. Commands live on its sidebar row, keeping
  // shell text at the top just like the native macOS TerminalPanel.
  if (previousBoard) {
    toolbar.className = "focus-bar";
    toolbar.append(
      button(
        "‹ Canvas",
        () => select({ kind: "canvas", id: previousBoard! }),
        "subtle",
      ),
      element("strong", instance.name),
    );
  }
  const session = sessions.get(instance.id);
  if (session) {
    content.append(session.element);
    session.setVisible(true, true);
    if (session.state === "ended" || session.state === "error") {
      const recovery = element("div", undefined, "session-recovery");
      recovery.append(
        element("span", "Session ended"),
        button("Restart", () => start(instance), "subtle"),
      );
      content.append(recovery);
    }
  } else renderReady(instance, content);
}
function renderWelcome(): void {
  const welcome = element("section", undefined, "welcome");
  welcome.append(
    icon("terminal"),
    element("h1", "Nothing Selected"),
    element(
      "p",
      `Select a terminal or canvas in the sidebar, or press ${data?.platform === "macos" ? "⌘T" : "Ctrl+Shift+T"} for a new terminal.`,
    ),
  );
  content.append(welcome);
}
function renderReady(instance: Instance, parent: HTMLElement): void {
  const box = element("div", undefined, "ready");
  box.append(
    element(
      "span",
      instance.spec.harness ? "AI SESSION" : "TERMINAL",
      "eyebrow",
    ),
    element("h2", instance.name),
    element(
      "p",
      instance.spec.workingDirectory || "Default folder",
      "directory",
    ),
  );
  box.append(
    button("Open session", () => start(instance), "primary"),
    button("Edit launch settings", () => editInstance(instance), "subtle"),
  );
  parent.append(box);
}
function start(instance: Instance): Promise<void> {
  const pending = starting.get(instance.id);
  if (pending) return pending;
  const opening = startSession(instance).finally(() =>
    starting.delete(instance.id),
  );
  starting.set(instance.id, opening);
  return opening;
}
async function startSession(instance: Instance): Promise<void> {
  const existing = sessions.get(instance.id);
  if (existing?.state === "running" || existing?.state === "opening") {
    select({ kind: "terminal", id: instance.id });
    return;
  }
  // Font files are bundled and preloaded. Wait for their metrics before xterm
  // constructs its canvas, avoiding platform fallback fonts and later reflow.
  await document.fonts.load('14px "Skylight Mono"');
  if (existing) {
    await existing.close();
    sessions.delete(instance.id);
  }
  const provider = data.providers.find((p) => p.id === instance.spec.harness);
  const program = instance.spec.harness
    ? provider?.executable
    : instance.spec.shellPath || data.defaultShell;
  if (!program)
    throw new Error(
      `${provider?.name ?? instance.spec.harness} is not installed or is outside PATH. Install it, then refresh the launch list.`,
    );
  const session = new TerminalSession(
    instance,
    () => {
      renderNav();
      if (
        selected?.id === instance.id ||
        (selected?.kind === "canvas" &&
          boardFor(workspace, instance.id)?.id === selected.id)
      )
        render();
    },
    report,
    activeAppearance,
  );
  session.element.addEventListener("focusin", () => {
    lastFocusedSession = instance.id;
  });
  sessions.set(instance.id, session);
  select({ kind: "terminal", id: instance.id });
  try {
    await session.start(
      program,
      instance.spec.workingDirectory || data.home || null,
    );
  } catch (error) {
    session.dispose();
    sessions.delete(instance.id);
    render();
    throw error;
  }
}
function dialog(title: string): {
  dialog: HTMLDialogElement;
  body: HTMLDivElement;
  close: () => void;
} {
  if (modal?.dataset.busy === "true")
    throw new Error("Wait for the appearance save to finish");
  modal?.close();
  modal?.remove();
  const dlg = element("dialog", undefined, "dialog");
  const heading = element("header");
  const close = () => {
    if (dlg.dataset.busy === "true") return;
    dlg.close();
    dlg.remove();
    if (modal === dlg) modal = undefined;
    restoreFocus();
  };
  const dismiss = button("", close, "icon-button");
  dismiss.append(icon("close"));
  dismiss.setAttribute("aria-label", "Close dialog");
  heading.append(element("h2", title), dismiss);
  const body = element("div", undefined, "dialog-body");
  dlg.append(heading, body);
  document.body.append(dlg);
  modal = dlg;
  dlg.addEventListener("cancel", (event) => {
    event.preventDefault();
    requestAnimationFrame(close);
  });
  return { dialog: dlg, body, close };
}
function restoreFocus(): void {
  if (selected?.kind === "terminal")
    sessions.get(selected.id)?.terminal.focus();
  else if (selected?.kind === "canvas" && lastFocusedSession) {
    const board = workspace.canvases.find((b) => b.id === selected!.id);
    if (
      board?.zoom === 1 &&
      board.tiles.some((t) => t.itemID === lastFocusedSession)
    )
      sessions.get(lastFocusedSession)?.terminal.focus();
  }
}
function field(label: string, value = "", placeholder = ""): HTMLInputElement {
  const input = element("input");
  input.value = value;
  input.placeholder = placeholder;
  input.setAttribute("aria-label", label);
  input.autocomplete = "off";
  input.spellcheck = false;
  return input;
}
function labeled(label: string, input: HTMLElement): HTMLLabelElement {
  const row = element("label");
  row.append(element("span", label), input);
  return row;
}
function quoteArgument(value: string): string {
  return `'${value.replace(/'/g, "'\\''")}'`;
}
async function editInstance(
  instance?: Instance,
  targetBoard?: Canvas,
): Promise<void> {
  const {
    dialog: dlg,
    body,
    close,
  } = dialog(instance ? "Launch settings" : "New terminal");
  if (!instance && workspace.launchPresets?.length) {
    const presets = element("section", undefined, "launch-presets");
    presets.append(element("h3", "SAVED PRESETS"));
    for (const preset of workspace.launchPresets) {
      const row = element("div", undefined, "preset-row");
      row.append(
        button(
          preset.name,
          () => {
            close();
            return launchPreset(preset, targetBoard);
          },
          "preset-launch",
        ),
      );
      const edit = button(
        "…",
        () => {
          editPreset(preset);
        },
        "preset-remove",
      );
      edit.setAttribute("aria-label", `Edit preset ${preset.name}`);
      row.append(edit);
      presets.append(row);
    }
    body.append(presets);
  }
  const form = element("form");
  const mode = element("select");
  mode.setAttribute("aria-label", "Run");
  const shell = element("option", "Shell");
  shell.value = "shell";
  mode.append(shell);
  for (const p of data.providers) {
    const opt = element(
      "option",
      p.name + (p.executable ? "" : " — not installed"),
    );
    opt.value = p.id;
    opt.disabled = !p.executable;
    mode.append(opt);
  }
  mode.value = instance?.spec.harness ?? "shell";
  const name = field("Name", instance?.name ?? "Terminal");
  const program = field(
    "Shell executable",
    instance?.spec.shellPath ?? data.defaultShell,
  );
  const cwd = field(
    "Working folder",
    instance?.spec.workingDirectory ?? data.home,
  );
  const args = field(
    "Arguments",
    instance?.spec.arguments.map(quoteArgument).join(" ") ?? "",
    "Optional arguments",
  );
  const programRow = labeled("Shell executable", program);
  programRow.hidden = mode.value !== "shell";
  mode.onchange = () => {
    programRow.hidden = mode.value !== "shell";
    if (!instance)
      name.value =
        mode.value === "shell"
          ? "Terminal"
          : data.providers.find((p) => p.id === mode.value)!.name;
  };
  const advanced = element("details", undefined, "advanced-launch");
  advanced.open = Boolean(instance);
  advanced.append(
    element("summary", "Launch options"),
    labeled("Name", name),
    programRow,
    labeled("Arguments", args),
  );
  form.append(labeled("Run", mode), labeled("Working folder", cwd), advanced);
  const help = element(
    "p",
    "Uses the CLI’s own sign-in and subscription. Restored or imported sessions open only when you choose.",
    "hint",
  );
  const actions = element("div", undefined, "dialog-actions");
  const submit = element(
    "button",
    instance ? "Save settings" : "Open terminal",
    "primary",
  );
  submit.type = "submit";
  if (instance && workspace.launchPresets?.some((p) => p.id === instance.id))
    actions.append(
      button(
        "Remove preset",
        async () => {
          if (
            await confirm(
              "Remove preset?",
              `Remove ${instance.name}? Existing sessions stay open.`,
              "Remove",
            )
          ) {
            workspace.launchPresets = workspace.launchPresets?.filter(
              (p) => p.id !== instance.id,
            );
            await persist();
          }
        },
        "subtle",
      ),
    );
  actions.append(button("Cancel", close, "subtle"), submit);
  form.append(help, actions);
  body.append(form);
  form.onsubmit = (event) => {
    event.preventDefault();
    void (async () => {
      submit.disabled = true;
      try {
        const spec = {
          ...(instance?.spec ?? {}),
          shellPath: mode.value === "shell" ? program.value : null,
          harness: mode.value === "shell" ? null : mode.value,
          workingDirectory: cwd.value || null,
          arguments: parseArguments(args.value),
        };
        if (instance) {
          instance.name = name.value.trim() || "Terminal";
          instance.spec = spec;
          await persist();
          close();
          render();
        } else {
          const item: Instance = {
            id: crypto.randomUUID(),
            name: name.value.trim() || "Terminal",
            spec,
          };
          workspace.instances.push(item);
          await persist();
          close();
          await start(item);
          if (targetBoard && workspace.canvases.includes(targetBoard)) {
            moveToCanvas(item, targetBoard);
            select({ kind: "canvas", id: targetBoard.id });
          }
        }
      } catch (error) {
        report(error);
        submit.disabled = false;
      }
    })();
  };
  dlg.showModal();
  if (instance) {
    name.focus();
    name.select();
  } else mode.focus();
  // Open immediately from the last discovery result. Slow PATH locations must
  // not hold up shell editing or create a delayed dialog after another action.
  mode.setAttribute("aria-busy", "true");
  providerRefresh ??= invoke<Bootstrap["providers"]>("refresh_providers")
    .then((providers) => {
      data.providers = providers;
    })
    .finally(() => {
      providerRefresh = undefined;
    });
  void providerRefresh
    .then(() => {
      if (modal !== dlg) return;
      for (const provider of data.providers) {
        const option = [...mode.options].find(
          (option) => option.value === provider.id,
        );
        if (!option) continue;
        option.disabled = !provider.executable;
        option.textContent =
          provider.name + (provider.executable ? "" : " — not installed");
      }
    })
    .catch((error) => {
      if (modal === dlg) report(error);
    })
    .finally(() => mode.removeAttribute("aria-busy"));
}
async function confirm(
  title: string,
  message: string,
  action = "Continue",
): Promise<boolean> {
  const { dialog: dlg, body, close } = dialog(title);
  body.append(element("p", message));
  return new Promise((resolve) => {
    const done = (result: boolean) => {
      close();
      resolve(result);
    };
    const actions = element("div", undefined, "dialog-actions");
    actions.append(
      button("Cancel", () => done(false), "subtle"),
      button(action, () => done(true), "primary"),
    );
    body.append(actions);
    dlg.addEventListener("cancel", () => resolve(false), { once: true });
    dlg.addEventListener("close", () => resolve(false), { once: true });
    dlg.showModal();
  });
}
async function removeInstance(instance: Instance): Promise<void> {
  if (
    sessions.get(instance.id)?.state === "running" &&
    !(await confirm(
      "Close this terminal?",
      `The process in ${instance.name} will end. This preview does not yet keep sessions running after close.`,
      "Close terminal",
    ))
  )
    return;
  const session = sessions.get(instance.id);
  if (session) {
    await session.close();
    sessions.delete(instance.id);
  }
  workspace.instances = workspace.instances.filter((i) => i.id !== instance.id);
  for (const board of workspace.canvases) {
    board.tiles = board.tiles.filter((t) => t.itemID !== instance.id);
    for (const rail of Object.values(board.docks))
      rail.slots = rail.slots.filter((s) => s.itemID !== instance.id);
  }
  workspace.selectedInstance = null;
  selected = undefined;
  await persist();
  render();
}
async function newCanvas(initialInstance?: Instance): Promise<void> {
  const { dialog: dlg, body, close } = dialog("New canvas");
  const name = field("Canvas name", "Untitled canvas");
  const form = element("form");
  const submit = element("button", "Create canvas", "primary");
  submit.type = "submit";
  form.append(labeled("Name", name), submit);
  body.append(form);
  form.onsubmit = (e) => {
    e.preventDefault();
    const board: Canvas = {
      id: crypto.randomUUID(),
      name: name.value.trim() || "Untitled canvas",
      tiles: [],
      docks: {},
      pan: [0, 0],
      zoom: 1,
    };
    workspace.canvases.push(board);
    if (initialInstance) moveToCanvas(initialInstance, board);
    close();
    select({ kind: "canvas", id: board.id });
  };
  dlg.showModal();
  name.select();
}
async function placeInstance(instance: Instance): Promise<void> {
  if (!workspace.canvases.length) {
    await newCanvas(instance);
    return;
  }
  const { dialog: dlg, body, close } = dialog("Move to canvas");
  for (const board of workspace.canvases)
    body.append(
      button(
        board.name,
        () => {
          moveToCanvas(instance, board);
          close();
          select({ kind: "canvas", id: board.id });
        },
        "choice-row",
      ),
    );
  dlg.showModal();
}
function moveToCanvas(instance: Instance, board: Canvas): void {
  for (const current of workspace.canvases) {
    current.tiles = current.tiles.filter((t) => t.itemID !== instance.id);
    for (const rail of Object.values(current.docks))
      rail.slots = rail.slots.filter((s) => s.itemID !== instance.id);
  }
  const count = board.tiles.length;
  board.tiles.push({
    id: crypto.randomUUID(),
    itemID: instance.id,
    origin: [32 + (count % 2) * 580, 32 + Math.floor(count / 2) * 400],
    size: [560, 400],
  });
  // Reveal the newly placed terminal at live scale, including on a board
  // that was panned away or already contains several tiles.
  const tile = board.tiles[board.tiles.length - 1];
  const viewport = document.querySelector("main")!;
  board.zoom = 1;
  board.pan = [
    (viewport.clientWidth - tile.size[0]) / 2 - tile.origin[0],
    (viewport.clientHeight - tile.size[1]) / 2 - tile.origin[1],
  ];
}
function queueNavigationSave(): void {
  clearTimeout(navigationSave);
  navigationSave = setTimeout(() => {
    navigationSave = undefined;
    void persist();
  }, 160);
}
function canvasZoom(
  board: Canvas,
  value: number,
  pivot?: readonly [number, number],
  continuous = false,
): void {
  const viewport = document.querySelector<HTMLElement>(".canvas-viewport");
  if (!viewport || viewport.dataset.dragging) return;
  const next = (continuous ? zoomAroundContinuous : zoomAround)(
    board.pan,
    board.zoom,
    value,
    pivot ?? [viewport.clientWidth / 2, viewport.clientHeight / 2],
  );
  board.zoom = next.zoom;
  board.pan = next.pan;
  canvasRefresh?.();
  if (board.zoom === 1) restoreFocus();
  queueNavigationSave();
}
function canvasFit(board: Canvas, arrange = false): void {
  const viewport = document.querySelector<HTMLElement>(".canvas-viewport");
  if (!viewport) return;
  const size = [viewport.clientWidth, viewport.clientHeight] as const;
  if (arrange) board.tiles = arrangeTiles(board.tiles, size);
  const fitted = fitToView(board.tiles, size);
  if (fitted) {
    board.zoom = fitted.zoom;
    board.pan = fitted.pan;
  }
  if (arrange) render();
  else canvasRefresh?.();
  void persist();
}
function canvasActions(board: Canvas): MenuAction[] {
  return [
    { label: "New terminal", run: () => editInstance(undefined, board) },
    { label: "Zoom out", run: () => canvasZoom(board, board.zoom - 0.1) },
    { label: "Zoom in", run: () => canvasZoom(board, board.zoom + 0.1) },
    { label: "Actual size (100%)", run: () => canvasZoom(board, 1) },
    { label: "Fit canvas", run: () => canvasFit(board) },
    { label: "Arrange terminals", run: () => canvasFit(board, true) },
  ];
}
function renderCanvas(board: Canvas): void {
  const viewport = element("div", undefined, "canvas-viewport");
  const plane = element("div", undefined, "canvas-plane");
  viewport.append(plane);
  viewport.tabIndex = 0;
  viewport.setAttribute(
    "aria-label",
    `${board.name}, ${Math.round(board.zoom * 100)}%`,
  );
  contextual(viewport, () => canvasActions(board));
  viewport.ondblclick = (event) => {
    if (event.target === viewport || event.target === plane)
      void editInstance(undefined, board).catch(report);
  };
  content.append(viewport);
  const transform = () => {
    plane.style.transform = `translate(${board.pan[0]}px,${board.pan[1]}px) scale(${board.zoom})`;
    viewport.style.backgroundSize = `${64 * board.zoom}px ${64 * board.zoom}px`;
    viewport.style.backgroundPosition = `${board.pan[0]}px ${board.pan[1]}px`;
    viewport.setAttribute(
      "aria-label",
      `${board.name}, ${Math.round(board.zoom * 100)}%`,
    );
    for (const overlay of viewport.querySelectorAll<HTMLButtonElement>(
      ".tile-overview",
    ))
      overlay.hidden = board.zoom === 1;
    for (const tile of board.tiles) {
      const session = sessions.get(tile.itemID);
      if (session) session.element.inert = board.zoom !== 1;
    }
  };
  canvasRefresh = transform;
  let pinchEnd: ReturnType<typeof setTimeout> | undefined;
  viewport.addEventListener(
    "wheel",
    (event) => {
      if (viewport.dataset.dragging) return;
      if (
        !event.ctrlKey &&
        board.zoom === 1 &&
        (event.target as HTMLElement).closest(".terminal-surface")
      )
        return;
      event.preventDefault();
      event.stopPropagation();
      const unit =
        event.deltaMode === 1
          ? 16
          : event.deltaMode === 2
            ? viewport.clientHeight
            : 1;
      if (event.ctrlKey) {
        const rect = viewport.getBoundingClientRect();
        const pivot = [
          event.clientX - rect.left,
          event.clientY - rect.top,
        ] as const;
        canvasZoom(
          board,
          board.zoom * Math.exp(-event.deltaY * unit * 0.008),
          pivot,
          true,
        );
        clearTimeout(pinchEnd);
        pinchEnd = setTimeout(() => {
          if (viewport.isConnected && Math.abs(board.zoom - 1) < 0.035)
            canvasZoom(board, 1, pivot);
        }, 120);
      } else {
        board.pan = [
          board.pan[0] - event.deltaX * unit,
          board.pan[1] - event.deltaY * unit,
        ];
        transform();
        queueNavigationSave();
      }
    },
    { passive: false, capture: true },
  );
  transform();
  viewport.onpointerdown = (e) => {
    if (e.button !== 0) return;
    if (e.target !== viewport && e.target !== plane) return;
    const start = [e.clientX, e.clientY];
    const pan = [...board.pan];
    viewport.dataset.dragging = "true";
    viewport.setPointerCapture(e.pointerId);
    viewport.onpointermove = (move) => {
      board.pan = [
        pan[0] + move.clientX - start[0],
        pan[1] + move.clientY - start[1],
      ];
      transform();
    };
    viewport.onpointerup = () => {
      viewport.onpointermove = null;
      delete viewport.dataset.dragging;
      void persist();
    };
    viewport.onpointercancel = viewport.onpointerup;
  };
  if (!residentIDs(board).length) {
    const empty = element("div", undefined, "canvas-empty");
    empty.append(
      element("h2", "Empty Canvas"),
      element(
        "p",
        "Double-click for a terminal. Right-click a terminal in the sidebar to move it here.",
      ),
    );
    viewport.append(empty);
  }
  for (const tile of board.tiles) {
    const instance = workspace.instances.find((i) => i.id === tile.itemID);
    if (!instance) continue;
    const card = element("section", undefined, "tile");
    card.style.left = `${tile.origin[0]}px`;
    card.style.top = `${tile.origin[1]}px`;
    card.style.width = `${tile.size[0]}px`;
    card.style.height = `${tile.size[1]}px`;
    const header = element("header");
    header.append(
      icon("terminal"),
      element("strong", instance.name),
      element("span", status(instance.id), "session-status"),
      button(
        "",
        () => select({ kind: "terminal", id: instance.id }),
        "icon-button",
      ),
    );
    header
      .querySelector("button")
      ?.setAttribute("aria-label", `Focus ${instance.name}`);
    header.querySelector("button")?.append(icon("expand"));
    const detach = button("", () => detachInstance(instance), "icon-button");
    detach.append(icon("close"));
    detach.setAttribute("aria-label", `Remove ${instance.name} from canvas`);
    header.append(detach);
    contextual(header, () => instanceActions(instance));
    header.ondblclick = (event) => {
      if (!(event.target as HTMLElement).closest("button"))
        select({ kind: "terminal", id: instance.id });
    };
    header.onpointerdown = (e) => {
      if (e.button !== 0) return;
      if ((e.target as HTMLElement).closest("button")) return;
      const point = [e.clientX, e.clientY];
      const origin = [...tile.origin];
      viewport.dataset.dragging = "true";
      header.setPointerCapture(e.pointerId);
      header.onpointermove = (move) => {
        tile.origin = [
          Math.round(origin[0] + (move.clientX - point[0]) / board.zoom),
          Math.round(origin[1] + (move.clientY - point[1]) / board.zoom),
        ];
        card.style.left = `${tile.origin[0]}px`;
        card.style.top = `${tile.origin[1]}px`;
      };
      header.onpointerup = () => {
        header.onpointermove = null;
        delete viewport.dataset.dragging;
        tile.origin = magnetSnap(
          tile,
          board.tiles.filter((t) => t.id !== tile.id),
          12 / board.zoom,
          96 / board.zoom,
        );
        card.style.left = `${tile.origin[0]}px`;
        card.style.top = `${tile.origin[1]}px`;
        void persist();
      };
      header.onpointercancel = header.onpointerup;
    };
    header
      .querySelector(".session-status")
      ?.classList.toggle("quiet", status(instance.id) === "running");
    const inside = element("div", undefined, "tile-content");
    card.append(header, inside);
    plane.append(card);
    const grip = button("", () => {}, "resize-grip");
    grip.append(icon("expand"));
    grip.setAttribute("aria-label", `Resize ${instance.name}`);
    card.append(grip);
    const setSize = (width: number, height: number) => {
      tile.size = [
        Math.max(320, Math.round(width)),
        Math.max(220, Math.round(height)),
      ];
      card.style.width = `${tile.size[0]}px`;
      card.style.height = `${tile.size[1]}px`;
    };
    grip.onpointerdown = (e) => {
      if (e.button !== 0) return;
      e.preventDefault();
      grip.focus();
      const point = [e.clientX, e.clientY];
      const size = [...tile.size];
      viewport.dataset.dragging = "true";
      grip.setPointerCapture(e.pointerId);
      grip.onpointermove = (move) =>
        setSize(
          size[0] + (move.clientX - point[0]) / board.zoom,
          size[1] + (move.clientY - point[1]) / board.zoom,
        );
      grip.onpointerup = () => {
        grip.onpointermove = null;
        delete viewport.dataset.dragging;
        setSize(...snapSize(tile.size));
        void persist();
      };
      grip.onpointercancel = grip.onpointerup;
    };
    grip.onkeydown = (e) => {
      const step = e.shiftKey ? 32 : 16;
      if (["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(e.key)) {
        e.preventDefault();
        setSize(
          tile.size[0] +
            (e.key === "ArrowRight" ? step : e.key === "ArrowLeft" ? -step : 0),
          tile.size[1] +
            (e.key === "ArrowDown" ? step : e.key === "ArrowUp" ? -step : 0),
        );
        void persist();
      }
    };
    const session = sessions.get(instance.id);
    if (session) {
      inside.append(session.element);
      session.setVisible(true);
      const overview = button(
        "",
        () => {
          board.zoom = 1;
          board.pan = [
            (viewport.clientWidth - tile.size[0]) / 2 - tile.origin[0],
            (viewport.clientHeight - tile.size[1]) / 2 - tile.origin[1],
          ];
          transform();
          session.terminal.focus();
          void persist();
        },
        "tile-overview",
      );
      overview.setAttribute("aria-label", `Open ${instance.name} at 100%`);
      overview.hidden = board.zoom === 1;
      session.element.inert = board.zoom !== 1;
      inside.append(overview);
    } else renderReady(instance, inside);
  }
  const docked = Object.values(board.docks)
    .flatMap((r) =>
      r.slots.map((s) => workspace.instances.find((i) => i.id === s.itemID)),
    )
    .filter((i): i is Instance => Boolean(i));
  if (docked.length) {
    const rail = element("div", undefined, "preserved-docks");
    rail.append(element("span", "Docked sessions"));
    for (const i of docked)
      rail.append(button(i.name, () => select({ kind: "terminal", id: i.id })));
    viewport.append(rail);
  }
}
function palette(): void {
  if (!workspace || modal) return;
  const { dialog: dlg, body, close } = dialog("Switch to");
  dlg.classList.add("switcher");
  const input = field(
    "Search workspace",
    "",
    "Find a terminal, canvas, or launch preset",
  );
  const list = element("div", undefined, "search-results");
  list.setAttribute("role", "listbox");
  let index = 0;
  let matches: SearchItem[] = [];
  const choose = (item: SearchItem) => {
    close();
    if (item.kind === "preset") {
      const preset = workspace.launchPresets?.find((p) => p.id === item.id);
      if (preset) void launchPreset(preset).catch(report);
    } else {
      select({ kind: item.kind, id: item.id });
    }
  };
  const update = () => {
    matches = search(
      input.value,
      searchItems(workspace, data.providers, data.platform),
    );
    index = Math.min(index, Math.max(0, matches.length - 1));
    list.replaceChildren();
    matches.forEach((item, i) => {
      const row = button("", () => choose(item), "search-row");
      row.setAttribute("role", "option");
      row.setAttribute("aria-selected", String(i === index));
      row.append(element("strong", item.name), element("span", item.detail));
      list.append(row);
    });
    if (!matches.length)
      list.append(
        element(
          "p",
          "No matches. Try a name, CLI, folder, canvas, or preset.",
          "no-results",
        ),
      );
    list.children[index]?.scrollIntoView({ block: "nearest" });
  };
  input.oninput = () => {
    index = 0;
    update();
  };
  input.onkeydown = (e) => {
    if (e.isComposing) return;
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      index = Math.max(
        0,
        Math.min(matches.length - 1, index + (e.key === "ArrowDown" ? 1 : -1)),
      );
      update();
    } else if (e.key === "Enter" && matches[index]) {
      e.preventDefault();
      choose(matches[index]);
    }
  };
  body.append(
    input,
    list,
    element("p", "↑↓ Navigate    Enter Open    Esc Close", "hint"),
  );
  dlg.showModal();
  update();
  input.focus();
}
async function importWorkspace(): Promise<void> {
  const document = await invoke<{
    workspace: Workspace | null;
    presets: Instance[];
  } | null>("import_workspace");
  if (!document) return;
  if (!document.workspace) {
    if (
      !(await confirm(
        "Import launch presets?",
        `${document.presets.length} presets will be added to Quick Launch. Review their folders and arguments before launching on this computer.`,
        "Import presets",
      ))
    )
      return;
    workspace.launchPresets ??= [];
    workspace.launchPresets.push(
      ...document.presets.map((p) => ({ ...p, id: crypto.randomUUID() })),
    );
    await persist();
    render();
    return;
  }
  const imported = document.workspace;
  if (
    !(await confirm(
      "Use this workspace?",
      `${imported.instances.length} terminals and ${imported.canvases.length} canvases. Current sessions will close. Imported sessions stay stopped until you review their launch settings and open them. Windows and Linux folders may need changing.`,
      "Use workspace",
    ))
  )
    return;
  await Promise.all([...sessions.values()].map((s) => s.close()));
  sessions.clear();
  workspace = imported;
  selected = undefined;
  workspace.selectedCanvas = null;
  workspace.selectedInstance = null;
  await persist();
  render();
}
function editPreset(preset: Instance): void {
  const { dialog: dlg, body, close } = dialog("Edit preset");
  const form = presetEditor(
    preset,
    data.platform,
    data.providers,
    async (updated) => {
      const previous = workspace.launchPresets;
      workspace.launchPresets = previous?.map((p) =>
        p.id === updated.id ? updated : p,
      );
      try {
        await persist();
      } catch (error) {
        workspace.launchPresets = previous;
        throw error;
      }
      close();
      renderNav();
    },
    close,
  );
  const remove = button(
    "Remove preset",
    async () => {
      if (
        await confirm(
          "Remove preset?",
          `Remove ${preset.name}? Existing sessions stay open.`,
          "Remove",
        )
      ) {
        workspace.launchPresets = workspace.launchPresets?.filter(
          (p) => p.id !== preset.id,
        );
        await persist();
      }
    },
    "subtle",
  );
  form.querySelector(".dialog-actions")!.prepend(remove);
  body.append(form);
  dlg.showModal();
}
async function launchPreset(
  preset: Instance,
  targetBoard?: Canvas,
): Promise<void> {
  const instance: Instance = {
    id: crypto.randomUUID(),
    name: preset.name,
    spec: structuredClone(presetSpec(preset, data.platform)),
  };
  workspace.instances.push(instance);
  await persist();
  await start(instance);
  if (targetBoard && workspace.canvases.includes(targetBoard)) {
    moveToCanvas(instance, targetBoard);
    select({ kind: "canvas", id: targetBoard.id });
  }
}
async function savePreset(instance: Instance): Promise<void> {
  const { dialog: dlg, body, close } = dialog("Save launch preset");
  const name = field("Preset name", instance.name);
  const form = element("form");
  const submit = element("button", "Save to Quick Launch", "primary");
  submit.type = "submit";
  form.append(
    labeled("Name", name),
    element(
      "p",
      "Save this shell or AI CLI, its folder, and its arguments. Each click creates a fresh session.",
      "hint",
    ),
    submit,
  );
  body.append(form);
  form.onsubmit = (e) => {
    e.preventDefault();
    workspace.launchPresets ??= [];
    workspace.launchPresets.push({
      id: crypto.randomUUID(),
      name: name.value.trim() || instance.name,
      spec: structuredClone(instance.spec),
    });
    close();
    void persist();
    renderNav();
  };
  dlg.showModal();
  name.select();
}
async function closeWindow(): Promise<void> {
  if (allowClose || modal?.dataset.busy === "true") return;
  const active = [...sessions.values()].filter(
    (s) => s.state === "running" || s.state === "opening",
  ).length;
  if (
    active &&
    !(await confirm(
      "Close Skylight?",
      `${active} active sessions will end. Workspace layouts will be saved. Session survival is still in development for this preview.`,
      "Close Skylight",
    ))
  )
    return;
  if (navigationSave) {
    clearTimeout(navigationSave);
    navigationSave = undefined;
    void persist();
  }
  await saving;
  await Promise.all([...sessions.values()].map((s) => s.close()));
  sessions.clear();
  allowClose = true;
  await getCurrentWindow().close();
}
document
  .querySelector("#new-terminal")!
  .replaceChildren(icon("plus"), element("span", "New"));
document.querySelector("#new-terminal")!.addEventListener("click", () => {
  void editInstance().catch(report);
});
document.querySelector("#switch")!.append(icon("search"));
document.querySelector("#switch")!.addEventListener("click", palette);
for (const id of ["sidebar-toggle", "sidebar-reveal"]) {
  const toggle = document.getElementById(id)!;
  toggle.append(icon("sidebar"));
  toggle.onclick = () => {
    const hidden = root.classList.toggle("sidebar-hidden");
    document.getElementById("sidebar-reveal")!.hidden = !hidden;
    document
      .getElementById(hidden ? "sidebar-reveal" : "sidebar-toggle")!
      .focus();
  };
}
document
  .querySelector("#workspace-menu")!
  .addEventListener("click", (event) => {
    const actions: MenuAction[] = [
      { label: "New terminal", run: () => editInstance() },
      { label: "New canvas", id: "new-canvas", run: () => newCanvas() },
      { label: "Search workspace", run: palette },
      { label: "Appearance", run: openAppearance },
      ...(appearanceHistory.previous
        ? [{ label: "Revert appearance", run: revertAppearance }]
        : []),
      { label: "Import workspace", run: importWorkspace },
      {
        label: "Export workspace",
        run: async () => {
          await invoke("export_workspace", { workspace });
        },
      },
    ];
    if (selected?.kind === "terminal") {
      const instance = workspace.instances.find((i) => i.id === selected!.id);
      if (instance) actions.push(...instanceActions(instance));
    } else if (selected?.kind === "canvas") {
      const board = workspace.canvases.find((b) => b.id === selected!.id);
      if (board) actions.push(...canvasActions(board).slice(1));
    }
    menuAt(event.currentTarget as HTMLElement, actions);
  });
document.addEventListener(
  "keydown",
  (e) => {
    if (modal?.dataset.busy === "true") return;
    const command =
      data?.platform === "macos" ? e.metaKey : e.ctrlKey && e.shiftKey;
    if (command && e.key === "," && !modal) {
      e.preventDefault();
      e.stopPropagation();
      void openAppearance().catch(report);
    } else if (command && e.key.toLowerCase() === "p") {
      e.preventDefault();
      e.stopPropagation();
      palette();
    } else if (command && e.key.toLowerCase() === "t" && !modal) {
      e.preventDefault();
      e.stopPropagation();
      void editInstance().catch(report);
    } else if (command && e.key === "." && previousBoard && !modal) {
      e.preventDefault();
      e.stopPropagation();
      select({ kind: "canvas", id: previousBoard });
    } else if (command && selected?.kind === "canvas" && !modal) {
      const board = workspace.canvases.find((b) => b.id === selected!.id);
      if (!board) return;
      // Plain Cmd+A remains text selection in the Mac development build.
      if (e.key.toLowerCase() === "a" && !e.shiftKey) return;
      if (["+", "=", "-", "_", "0", ")", "9", "(", "a", "A"].includes(e.key)) {
        e.preventDefault();
        e.stopPropagation();
        if (["+", "="].includes(e.key)) canvasZoom(board, board.zoom + 0.1);
        else if (["-", "_"].includes(e.key))
          canvasZoom(board, board.zoom - 0.1);
        else if (["0", ")"].includes(e.key)) canvasZoom(board, 1);
        else canvasFit(board, e.key.toLowerCase() === "a");
      }
    }
  },
  { capture: true },
);
async function boot(): Promise<void> {
  if (!isTauri()) {
    content.append(
      element(
        "div",
        "Open Skylight through the desktop app to use real terminal sessions.",
        "welcome",
      ),
    );
    return;
  }
  data = await invoke<Bootstrap>("bootstrap");
  workspace = data.workspace;
  try {
    appearanceHistory = await invoke<AppearanceHistory>("get_appearance");
  } catch (error) {
    report(
      `Saved appearance could not be read. It has not been replaced. ${String(error)}`,
    );
  }
  previewAppearance(appearanceHistory.current);
  root.dataset.ready = "true";
  selected = workspace.selectedInstance
    ? { kind: "terminal", id: workspace.selectedInstance }
    : workspace.selectedCanvas
      ? { kind: "canvas", id: workspace.selectedCanvas }
      : undefined;
  render();
  await getCurrentWindow().onCloseRequested((event) => {
    if (!allowClose) {
      event.preventDefault();
      void closeWindow().catch(report);
    }
  });
}
void boot().catch((error) => {
  content.append(
    element(
      "section",
      "Workspace could not be opened. Your saved file has not been replaced.",
      "welcome",
    ),
  );
  report(error);
});

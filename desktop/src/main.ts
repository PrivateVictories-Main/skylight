import { invoke, isTauri } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { TerminalSession } from "./terminal";
import {
  boardFor,
  parseArguments,
  residentIDs,
  search,
  searchItems,
  type Bootstrap,
  type Canvas,
  type Instance,
  type SearchItem,
  type Workspace,
} from "./model";
import "./style.css";

const root = document.querySelector<HTMLDivElement>("#app")!;
root.innerHTML = `<aside class="sidebar"><header><span class="mark" aria-hidden="true">▱</span><strong>Skylight</strong><span class="preview">PREVIEW</span></header><div class="sidebar-actions"><button id="new-terminal">＋ New terminal</button><button id="switch" aria-label="Search workspace">⌕</button></div><nav id="sessions" aria-label="Workspace"></nav><footer><button id="new-canvas">＋ Canvas</button><div><button id="import">Import</button><button id="export">Export</button></div><span id="platform"></span></footer></aside><main><header id="toolbar"></header><div id="content"></div><div id="notice" role="status" hidden></div></main>`;
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
let allowClose = false;
const sessions = new Map<string, TerminalSession>();

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
function renderNav(): void {
  nav.replaceChildren();
  const addInstance = (instance: Instance) => {
    const row = button(
      "",
      () => select({ kind: "terminal", id: instance.id }),
      "session-row",
    );
    row.classList.toggle("selected", selected?.id === instance.id);
    row.setAttribute("aria-label", `${instance.name}, ${status(instance.id)}`);
    row.append(
      element(
        "span",
        "●",
        `state-dot ${sessions.get(instance.id)?.state ?? ""}`,
      ),
      element("span", instance.name, "row-name"),
    );
    if (instance.spec.harness) row.append(element("span", "AI", "agent-label"));
    nav.append(row);
  };
  const presets = workspace.launchPresets ?? [];
  if (presets.length) {
    nav.append(element("h2", "QUICK LAUNCH"));
    for (const preset of presets) {
      const row = element("div", undefined, "preset-row");
      row.append(
        button(preset.name, () => launchPreset(preset), "preset-launch"),
        button("…", () => editInstance(preset), "preset-remove"),
        button(
          "×",
          async () => {
            if (
              await confirm(
                "Remove preset?",
                `Remove ${preset.name} from Quick Launch? Existing sessions stay open.`,
                "Remove",
              )
            ) {
              workspace.launchPresets = presets.filter(
                (p) => p.id !== preset.id,
              );
              await persist();
              renderNav();
            }
          },
          "preset-remove",
        ),
      );
      row.children[1].setAttribute("aria-label", `Edit preset ${preset.name}`);
      row.children[2].setAttribute(
        "aria-label",
        `Remove preset ${preset.name}`,
      );
      nav.append(row);
    }
  }
  nav.append(element("h2", "TERMINALS"));
  workspace.instances
    .filter((i) => !boardFor(workspace, i.id))
    .forEach(addInstance);
  for (const board of workspace.canvases) {
    const row = button(
      "",
      () => select({ kind: "canvas", id: board.id }),
      "canvas-row",
    );
    row.classList.toggle("selected", selected?.id === board.id);
    row.append(
      element("span", "▦"),
      element("span", board.name, "row-name"),
      element("span", String(residentIDs(board).length), "count"),
    );
    nav.append(row);
    residentIDs(board).forEach((id) => {
      const i = workspace.instances.find((i) => i.id === id);
      if (i) addInstance(i);
    });
  }
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
  for (const session of sessions.values()) session.setVisible(false);
  renderNav();
  toolbar.replaceChildren();
  content.replaceChildren();
  if (!selected) {
    renderWelcome();
    return;
  }
  if (selected.kind === "canvas") {
    const board = workspace.canvases.find((b) => b.id === selected!.id);
    if (board) renderCanvas(board);
    else renderWelcome();
    return;
  }
  const instance = workspace.instances.find((i) => i.id === selected!.id);
  if (!instance) {
    renderWelcome();
    return;
  }
  if (previousBoard)
    toolbar.append(
      button(
        "‹ Canvas",
        () => select({ kind: "canvas", id: previousBoard! }),
        "subtle",
      ),
    );
  toolbar.append(
    element("strong", instance.name),
    element("span", status(instance.id), "session-status"),
    element("span", "", "spacer"),
  );
  toolbar.append(
    button("Save preset", () => savePreset(instance), "subtle"),
    button("Edit", () => editInstance(instance), "subtle"),
    button("Move to canvas", () => placeInstance(instance), "subtle"),
    button("Close", () => removeInstance(instance), "subtle"),
  );
  const session = sessions.get(instance.id);
  if (session) {
    content.append(session.element);
    session.setVisible(true, true);
    if (session.state === "ended" || session.state === "error")
      toolbar.append(button("Restart", () => start(instance), "primary"));
  } else renderReady(instance, content);
}
function renderWelcome(): void {
  toolbar.append(element("strong", "Workspace"));
  const welcome = element("section", undefined, "welcome");
  welcome.append(
    element("div", "▱", "welcome-mark"),
    element("h1", "Make room for your work."),
    element(
      "p",
      "Open a shell or an installed AI CLI. Keep each project together.",
    ),
    button("New terminal", () => editInstance(), "primary"),
    button("Import a workspace", importWorkspace, "subtle"),
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
async function start(instance: Instance): Promise<void> {
  const existing = sessions.get(instance.id);
  if (existing?.state === "running" || existing?.state === "opening") {
    select({ kind: "terminal", id: instance.id });
    return;
  }
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
      if (selected?.id === instance.id) render();
    },
    report,
  );
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
  modal?.close();
  modal?.remove();
  const dlg = element("dialog", undefined, "dialog");
  const heading = element("header");
  const close = () => {
    dlg.close();
    dlg.remove();
    if (modal === dlg) modal = undefined;
    restoreFocus();
  };
  heading.append(element("h2", title), button("×", close, "icon-button"));
  const body = element("div", undefined, "dialog-body");
  dlg.append(heading, body);
  document.body.append(dlg);
  modal = dlg;
  dlg.addEventListener("cancel", () => {
    requestAnimationFrame(close);
  });
  return { dialog: dlg, body, close };
}
function restoreFocus(): void {
  if (selected?.kind === "terminal")
    sessions.get(selected.id)?.terminal.focus();
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
async function editInstance(instance?: Instance): Promise<void> {
  try {
    data.providers = await invoke("refresh_providers");
  } catch (error) {
    report(error);
  }
  const {
    dialog: dlg,
    body,
    close,
  } = dialog(instance ? "Launch settings" : "New terminal");
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
  form.append(
    labeled("Run", mode),
    labeled("Name", name),
    programRow,
    labeled("Working folder", cwd),
    labeled("Arguments", args),
  );
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
        }
      } catch (error) {
        report(error);
        submit.disabled = false;
      }
    })();
  };
  dlg.showModal();
  name.focus();
  name.select();
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
async function newCanvas(): Promise<void> {
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
    close();
    select({ kind: "canvas", id: board.id });
  };
  dlg.showModal();
  name.select();
}
async function placeInstance(instance: Instance): Promise<void> {
  if (!workspace.canvases.length) {
    await newCanvas();
    return;
  }
  const { dialog: dlg, body, close } = dialog("Move to canvas");
  for (const board of workspace.canvases)
    body.append(
      button(
        board.name,
        () => {
          for (const current of workspace.canvases) {
            current.tiles = current.tiles.filter(
              (t) => t.itemID !== instance.id,
            );
            for (const rail of Object.values(current.docks))
              rail.slots = rail.slots.filter((s) => s.itemID !== instance.id);
          }
          const count = board.tiles.length;
          board.tiles.push({
            id: crypto.randomUUID(),
            itemID: instance.id,
            origin: [32 + (count % 2) * 580, 32 + Math.floor(count / 2) * 400],
            size: [540, 360],
          });
          close();
          select({ kind: "canvas", id: board.id });
        },
        "choice-row",
      ),
    );
  dlg.showModal();
}
function renderCanvas(board: Canvas): void {
  toolbar.append(
    element("strong", board.name),
    element("span", "", "spacer"),
    button("−", () => zoom(0.1 * -1), "subtle"),
    element("span", `${Math.round(board.zoom * 100)}%`, "zoom"),
    button("+", () => zoom(0.1), "subtle"),
    button(
      "100%",
      () => {
        board.zoom = 1;
        render();
        void persist();
      },
      "subtle",
    ),
  );
  function zoom(delta: number) {
    board.zoom = Math.max(
      0.25,
      Math.min(2, Math.round((board.zoom + delta) * 100) / 100),
    );
    render();
    void persist();
  }
  const viewport = element("div", undefined, "canvas-viewport");
  const plane = element("div", undefined, "canvas-plane");
  viewport.append(plane);
  content.append(viewport);
  const transform = () => {
    plane.style.transform = `translate(${board.pan[0]}px,${board.pan[1]}px) scale(${board.zoom})`;
  };
  transform();
  viewport.onpointerdown = (e) => {
    if (e.target !== viewport && e.target !== plane) return;
    const start = [e.clientX, e.clientY];
    const pan = [...board.pan];
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
      void persist();
    };
  };
  if (!residentIDs(board).length) {
    const empty = element("div", undefined, "canvas-empty");
    empty.append(
      element("h2", "Room for a project"),
      element(
        "p",
        "Open a terminal, then use “Move to canvas” to place it here.",
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
      element("strong", instance.name),
      element("span", status(instance.id), "session-status"),
      button(
        "↗",
        () => select({ kind: "terminal", id: instance.id }),
        "icon-button",
      ),
    );
    header
      .querySelector("button")
      ?.setAttribute("aria-label", `Focus ${instance.name}`);
    header.onpointerdown = (e) => {
      if ((e.target as HTMLElement).closest("button")) return;
      const point = [e.clientX, e.clientY];
      const origin = [...tile.origin];
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
        void persist();
      };
    };
    const inside = element("div", undefined, "tile-content");
    card.append(header, inside);
    plane.append(card);
    const grip = button("⌟", () => {}, "resize-grip");
    grip.setAttribute("aria-label", `Resize ${instance.name}`);
    card.append(grip);
    const setSize = (width: number, height: number) => {
      tile.size = [
        Math.max(320, Math.round(width)),
        Math.max(180, Math.round(height)),
      ];
      card.style.width = `${tile.size[0]}px`;
      card.style.height = `${tile.size[1]}px`;
    };
    grip.onpointerdown = (e) => {
      e.preventDefault();
      grip.focus();
      const point = [e.clientX, e.clientY];
      const size = [...tile.size];
      grip.setPointerCapture(e.pointerId);
      grip.onpointermove = (move) =>
        setSize(
          size[0] + (move.clientX - point[0]) / board.zoom,
          size[1] + (move.clientY - point[1]) / board.zoom,
        );
      grip.onpointerup = () => {
        grip.onpointermove = null;
        void persist();
      };
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
    if (session && board.zoom === 1) {
      inside.append(session.element);
      session.setVisible(true);
    } else if (session) {
      inside.append(
        element(
          "p",
          `${instance.spec.harness ?? "Terminal"} · ${status(instance.id)}`,
        ),
        button(
          "Focus terminal",
          () => select({ kind: "terminal", id: instance.id }),
          "subtle",
        ),
      );
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
    matches = search(input.value, searchItems(workspace, data.providers));
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
async function launchPreset(preset: Instance): Promise<void> {
  const instance: Instance = {
    id: crypto.randomUUID(),
    name: preset.name,
    spec: structuredClone(preset.spec),
  };
  workspace.instances.push(instance);
  await persist();
  await start(instance);
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
  if (allowClose) return;
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
  await saving;
  await Promise.all([...sessions.values()].map((s) => s.close()));
  sessions.clear();
  allowClose = true;
  await getCurrentWindow().close();
}
document.querySelector("#new-terminal")!.addEventListener("click", () => {
  void editInstance().catch(report);
});
document.querySelector("#new-canvas")!.addEventListener("click", () => {
  void newCanvas().catch(report);
});
document.querySelector("#switch")!.addEventListener("click", palette);
document.querySelector("#import")!.addEventListener("click", () => {
  void importWorkspace().catch(report);
});
document.querySelector("#export")!.addEventListener("click", () => {
  void invoke("export_workspace", { workspace }).catch(report);
});
document.addEventListener("keydown", (e) => {
  const command =
    data?.platform === "macos" ? e.metaKey : e.ctrlKey && e.shiftKey;
  if (command && e.key.toLowerCase() === "p") {
    e.preventDefault();
    palette();
  } else if (command && e.key.toLowerCase() === "t" && !modal) {
    e.preventDefault();
    void editInstance().catch(report);
  } else if (command && e.key === "." && previousBoard && !modal) {
    e.preventDefault();
    select({ kind: "canvas", id: previousBoard });
  }
});
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
  document.querySelector("#platform")!.textContent =
    `${data.platform === "macos" ? "Development host" : data.platform === "windows" ? "Windows" : "Linux"} · Local workspace`;
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

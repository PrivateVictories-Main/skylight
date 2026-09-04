import {
  parseArguments,
  presetSpec,
  type Instance,
  type Provider,
} from "./model";

/** Local draft: switching platforms and cancelling cannot change the live preset. */
export function presetEditor(
  preset: Instance,
  platform: string,
  providers: Provider[],
  save: (updated: Instance) => Promise<void>,
  cancel: () => void,
): HTMLFormElement {
  const draft = structuredClone(preset);
  const form = document.createElement("form");
  const label = (name: string, input: HTMLElement) => {
    const row = document.createElement("label");
    const caption = document.createElement("span");
    caption.textContent = name;
    input.setAttribute("aria-label", name);
    row.append(caption, input);
    return row;
  };
  const input = (value = "") => {
    const node = document.createElement("input");
    node.value = value;
    node.autocomplete = "off";
    node.spellcheck = false;
    return node;
  };
  const option = (value: string, title: string) => {
    const node = document.createElement("option");
    node.value = value;
    node.textContent = title;
    return node;
  };
  const name = input(draft.name);
  name.required = true;
  const scope = document.createElement("select");
  scope.append(
    ...[
      ["default", "Defaults"],
      ["macos", "macOS"],
      ["windows", "Windows"],
      ["linux", "Linux"],
    ].map(([value, title]) => option(value, title)),
  );
  scope.value = ["macos", "windows", "linux"].includes(platform)
    ? platform
    : "default";
  let current = scope.value;
  const custom = input();
  custom.type = "checkbox";
  const customRow = label("Use custom settings", custom);
  customRow.className = "preset-custom-toggle";
  const note = document.createElement("p");
  note.className = "hint";
  const mode = document.createElement("select");
  mode.append(
    option("", "Shell"),
    ...providers.map((p) => option(p.id, p.name)),
  );
  const shell = input();
  shell.placeholder = "Local default shell";
  const cwd = input();
  cwd.placeholder = "Home folder";
  const args = input();
  const shellRow = label("Shell executable", shell);
  const fields = document.createElement("fieldset");
  fields.className = "preset-fields";
  fields.append(
    label("Run", mode),
    shellRow,
    label("Working folder", cwd),
    label("Arguments", args),
  );
  const quote = (value: string) => `'${value.replace(/'/g, "'\\''")}'`;
  const store = () => {
    if (current !== "default" && !custom.checked) {
      if (draft.platformSpecs) delete draft.platformSpecs[current];
    } else {
      const spec = {
        ...presetSpec(draft, current),
        shellPath: shell.value || null,
        harness: mode.value || null,
        workingDirectory: cwd.value || null,
        arguments: parseArguments(args.value),
      };
      if (current === "default") draft.spec = spec;
      else {
        draft.platformSpecs ??= {};
        draft.platformSpecs[current] = spec;
      }
    }
    if (draft.platformSpecs && !Object.keys(draft.platformSpecs).length)
      delete draft.platformSpecs;
  };
  const updateControls = () => {
    customRow.hidden = current === "default";
    fields.disabled = current !== "default" && !custom.checked;
    shellRow.hidden = Boolean(mode.value);
    note.textContent =
      current === "default"
        ? "Used by operating systems without custom settings."
        : custom.checked
          ? "Only this operating system uses these launch settings."
          : "This operating system uses the preset defaults.";
  };
  const load = () => {
    const spec = presetSpec(draft, current);
    custom.checked = Boolean(draft.platformSpecs?.[current]);
    if (
      spec.harness &&
      ![...mode.options].some((o) => o.value === spec.harness)
    )
      mode.append(option(spec.harness, spec.harness));
    mode.value = spec.harness ?? "";
    shell.value = spec.shellPath ?? "";
    cwd.value = spec.workingDirectory ?? "";
    args.value = spec.arguments.map(quote).join(" ");
    updateControls();
  };
  scope.onchange = () => {
    store();
    current = scope.value;
    load();
  };
  custom.onchange = () => {
    if (!custom.checked) {
      const spec = draft.spec;
      if (
        spec.harness &&
        ![...mode.options].some((o) => o.value === spec.harness)
      )
        mode.append(option(spec.harness, spec.harness));
      mode.value = spec.harness ?? "";
      shell.value = spec.shellPath ?? "";
      cwd.value = spec.workingDirectory ?? "";
      args.value = spec.arguments.map(quote).join(" ");
    }
    updateControls();
  };
  mode.onchange = updateControls;
  const error = document.createElement("p");
  error.setAttribute("role", "alert");
  error.hidden = true;
  const actions = document.createElement("div");
  actions.className = "dialog-actions";
  const cancelButton = document.createElement("button");
  cancelButton.type = "button";
  cancelButton.textContent = "Cancel";
  cancelButton.onclick = cancel;
  const submit = document.createElement("button");
  submit.type = "submit";
  submit.className = "primary";
  submit.textContent = "Save preset";
  actions.append(cancelButton, submit);
  form.append(
    label("Preset name", name),
    label("Settings for", scope),
    customRow,
    note,
    fields,
    error,
    actions,
  );
  form.onsubmit = (event) => {
    event.preventDefault();
    if (!name.value.trim()) return;
    store();
    draft.name = name.value.trim();
    submit.disabled = true;
    void save(draft).catch((failure) => {
      error.textContent = String(failure);
      error.hidden = false;
      submit.disabled = false;
    });
  };
  load();
  return form;
}

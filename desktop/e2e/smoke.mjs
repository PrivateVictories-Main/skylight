// Real native WebDriver input and real PTYs. No mocked Tauri commands or providers.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import {
  mkdir,
  mkdtemp,
  readFile,
  readlink,
  readdir,
  writeFile,
} from "node:fs/promises";
import { homedir, platform, release, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

const windows = platform() === "win32";
assert(
  windows || platform() === "linux",
  "Run on Windows or Linux with its native WebDriver",
);
const resultDir = resolve("e2e/results");
await mkdir(resultDir, { recursive: true });
const support = await mkdtemp(join(tmpdir(), "skylight-ui-"));
const project = join(support, "project with spaces");
await mkdir(project);
const application = resolve(
  `target/release/skylight-desktop${windows ? ".exe" : ""}`,
);
const evidence = {
  platform: platform(),
  release: release(),
  application,
  checks: [],
  success: false,
};
let session;
let driverLog = "";
let driverError;
const driver = spawn(
  join(homedir(), ".cargo/bin", `tauri-driver${windows ? ".exe" : ""}`),
  [],
  {
    env: { ...process.env, SKYLIGHT_PORTABLE_SUPPORT_DIR: support },
    stdio: ["ignore", "pipe", "pipe"],
    detached: !windows,
  },
);
driver.on("error", (error) => {
  driverError = error;
});
for (const stream of [driver.stdout, driver.stderr]) {
  stream.on("data", (chunk) => {
    driverLog = (driverLog + chunk).slice(-100_000);
  });
}
async function request(method, path, body) {
  if (driverError) throw driverError;
  const response = await fetch(`http://127.0.0.1:4444${path}`, {
    method,
    headers: { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(30_000),
  });
  const payload = await response.json();
  if (!response.ok || payload.value?.error)
    throw new Error(`${method} ${path}: ${JSON.stringify(payload.value)}`);
  return payload.value;
}
const command = (method, path, body) =>
  request(method, `/session/${session}${path}`, body);
async function until(label, predicate, timeout = 15_000) {
  const deadline = Date.now() + timeout;
  let last;
  while (Date.now() < deadline) {
    try {
      const value = await predicate();
      if (value) return value;
    } catch (error) {
      last = error;
    }
    await delay(150);
  }
  throw new Error(`Timed out: ${label}${last ? `: ${last.message}` : ""}`);
}
const inspect = (script) =>
  command("POST", "/execute/sync", { script, args: [] });
async function find(value, using = "css selector") {
  const element = await command("POST", "/element", { using, value });
  return element["element-6066-11e4-a52e-4f735466cecf"];
}
async function click(selector) {
  const id = await until(selector, () => find(selector));
  try {
    await command("POST", `/element/${id}/click`, {});
  } catch (error) {
    const hit =
      await inspect(`const target = document.querySelector(${JSON.stringify(selector)});
      const rect = target?.getBoundingClientRect();
      return rect ? {rect: rect.toJSON(), hit: document.elementFromPoint(rect.x + rect.width / 2, rect.y + rect.height / 2)?.outerHTML.slice(0, 500)} : null;`).catch(
        () => null,
      );
    throw new Error(`${error.message}; hit test: ${JSON.stringify(hit)}`);
  }
}
async function clickText(text) {
  const id = await until(text, () =>
    find(`//button[normalize-space(.)='${text}']`, "xpath"),
  );
  await command("POST", `/element/${id}/click`, {});
}
async function fill(label, text) {
  const id = await until(label, () => find(`input[aria-label="${label}"]`));
  await command("POST", `/element/${id}/clear`, {});
  if (text)
    await command("POST", `/element/${id}/value`, { text, value: [...text] });
}
async function keys(text) {
  await command("POST", "/actions", {
    actions: [
      {
        type: "key",
        id: "keyboard",
        actions: [...text].flatMap((value) => [
          { type: "keyDown", value },
          { type: "keyUp", value },
        ]),
      },
    ],
  });
}
async function screenshot(name) {
  // A shell marker proves execution, not that the browser compositor has
  // presented the next terminal frame. Give screenshot evidence a paint turn.
  await delay(250);
  const png = await command("GET", "/screenshot");
  await writeFile(join(resultDir, `${name}.png`), Buffer.from(png, "base64"));
}
async function check(name, action) {
  const start = performance.now();
  await action();
  evidence.checks.push({
    name,
    elapsedMs: Math.round(performance.now() - start),
  });
  console.log(`PASS ${name}`);
}
const running = () =>
  until("running terminal", () =>
    inspect(
      "return document.querySelector('#content')?.dataset.sessionState === 'running'",
    ),
  );
const ended = () =>
  until("ended terminal", () =>
    inspect(
      "return document.querySelector('#content')?.dataset.sessionState === 'ended'",
    ),
  );
async function marker(name, focus = true) {
  // Moving a terminal schedules its fit for the next animation frame. The
  // backing grid can still have full-window dimensions inside a smaller tile.
  // Wait for that real layout, then click the visible host, not a clipped grid.
  await until("terminal fitted to its visible surface", () =>
    inspect(`
    const host = document.querySelector('.terminal-surface');
    const screen = host?.querySelector('.xterm-screen');
    if (!host || !screen) return false;
    const bounds = screen.getBoundingClientRect();
    return bounds.width > 0 && bounds.height > 0 &&
      bounds.width <= host.clientWidth + 1 && bounds.height <= host.clientHeight + 1;
  `),
  );
  if (focus) await click(".terminal-surface");
  await until("terminal keyboard focus", () =>
    inspect(
      "return document.activeElement?.classList.contains('xterm-helper-textarea')",
    ),
  );
  await keys(`echo SKYLIGHT_${name}>${name}.txt\uE007`);
  await until(
    `real shell marker ${name}`,
    async () =>
      (await readFile(join(project, `${name}.txt`), "utf8")).trim() ===
      `SKYLIGHT_${name}`,
  );
}
async function openApp() {
  const result = await request("POST", "/session", {
    capabilities: {
      alwaysMatch: { browserName: "wry", "tauri:options": { application } },
    },
  });
  session = result.sessionId;
  await until("workspace ready", () =>
    inspect("return document.querySelector('#app')?.dataset.ready === 'true'"),
  );
}
try {
  await until("native driver ready", () => request("GET", "/status"), 30_000);
  await check("Native app startup", openApp);
  await check("Create shell with explicit working folder", async () => {
    await click("#new-terminal");
    await click(".advanced-launch summary");
    await fill("Name", "QA shell");
    await fill(
      "Shell executable",
      windows ? "C:\\Windows\\System32\\cmd.exe" : "/bin/sh",
    );
    await fill("Working folder", project);
    await fill("Arguments", windows ? "/Q /D" : "");
    assert.equal(
      await inspect(
        "return document.querySelector('select[aria-label=Run]').options.length",
      ),
      12,
    );
    await clickText("Open terminal");
    await running();
    await marker("initial", false);
    await screenshot("terminal");
    const visual = await inspect(`
      const main = document.querySelector('main').getBoundingClientRect();
      const panel = document.querySelector('#content');
      return {
        sidebar: document.querySelector('.sidebar').getBoundingClientRect().width,
        panelInset: panel.getBoundingClientRect().top - main.top,
        radius: getComputedStyle(panel).borderRadius,
        toolbarHeight: document.querySelector('#toolbar').getBoundingClientRect().height,
        presetsInSidebar: document.querySelectorAll('#sessions .preset-row').length,
      };
    `);
    assert.deepEqual(visual, {
      sidebar: 256,
      panelInset: 8,
      radius: "16px",
      toolbarHeight: 0,
      presetsInSidebar: 0,
    });
    evidence.visualContract = visual;
    assert.equal(
      await inspect(
        `return document.fonts.check('14px "Skylight Mono"') && document.fonts.check('13px "Skylight UI"')`,
      ),
      true,
    );
    const fonts = await inspect(
      `return [...document.fonts].filter(font => font.status === 'loaded').map(font => font.family.replaceAll('"', '')).sort()`,
    );
    assert.deepEqual(fonts, ["Skylight Mono", "Skylight UI"]);
    evidence.bundledFonts = fonts;
  });
  await check(
    "Sidebar collapse and menu keyboard dismissal preserve terminal input",
    async () => {
      await click("#sidebar-toggle");
      assert.equal(
        await inspect(
          "return document.querySelector('.sidebar').getBoundingClientRect().width",
        ),
        0,
      );
      await marker("collapsed");
      await click("#sidebar-reveal");
      await marker("expanded");
      await click("#workspace-menu");
      await keys("\uE015\uE00C");
      assert.equal(
        await inspect("return document.querySelectorAll('[role=menu]').length"),
        0,
      );
      await marker("menu_dismissed");
    },
  );
  await check("Save reusable launch preset", async () => {
    await click("#workspace-menu");
    await clickText("Save preset");
    await fill("Preset name", "Daily shell");
    await clickText("Save to Quick Launch");
    await until(
      "preset saved",
      async () =>
        JSON.parse(await readFile(join(support, "workspace.json"), "utf8"))
          .launchPresets.length === 1,
    );
    await marker("after_preset", false);
    await click("#new-terminal");
    await until("preset in New dialog", () => find("dialog .preset-launch"));
    await screenshot("new-terminal");
    await keys("\uE00C");
    await marker("after_launch_dialog", false);
  });
  await check(
    "Platform preset editor isolates local defaults and preserves other systems",
    async () => {
      await click("#new-terminal");
      await click('[aria-label="Edit preset Daily shell"]');
      await click('select[aria-label="Settings for"] option[value="default"]');
      await fill("Working folder", join(support, "missing default folder"));
      await fill("Arguments", "--default-only");
      const other = windows ? "linux" : "windows";
      await click(`select[aria-label="Settings for"] option[value="${other}"]`);
      await click('input[aria-label="Use custom settings"]');
      await fill("Shell executable", "/foreign/shell");
      await fill("Working folder", "/foreign/project");
      await fill("Arguments", "--foreign-only");
      const local = windows ? "windows" : "linux";
      await click(`select[aria-label="Settings for"] option[value="${local}"]`);
      await click('input[aria-label="Use custom settings"]');
      await fill(
        "Shell executable",
        windows ? "C:\\Windows\\System32\\cmd.exe" : "/bin/sh",
      );
      await fill("Working folder", project);
      await fill("Arguments", windows ? "/Q /D" : "");
      await screenshot("platform-preset");
      await clickText("Save preset");
      await until("platform settings durably saved", async () => {
        const preset = JSON.parse(
          await readFile(join(support, "workspace.json"), "utf8"),
        ).launchPresets[0];
        return (
          preset.platformSpecs?.[local]?.workingDirectory === project &&
          preset.platformSpecs?.[other]?.arguments[0] === "--foreign-only" &&
          preset.spec.arguments[0] === "--default-only"
        );
      });
      // Cancel a second edit. Neither defaults nor another OS may be overwritten.
      await click("#new-terminal");
      await click('[aria-label="Edit preset Daily shell"]');
      await fill("Working folder", "/cancelled/edit");
      await clickText("Cancel");
      await marker("after_preset_edit", false);
      const preset = JSON.parse(
        await readFile(join(support, "workspace.json"), "utf8"),
      ).launchPresets[0];
      assert.equal(preset.platformSpecs[local].workingDirectory, project);
    },
  );
  await check("Create canvas and move live terminal", async () => {
    // The first move must create the canvas AND place the terminal in it.
    await click("#workspace-menu");
    await clickText("Move to canvas");
    await fill("Canvas name", "QA canvas");
    await clickText("Create canvas");
    await until("first move completed", () => find(".tile .xterm-screen"));
    await click("#workspace-menu");
    await click("#new-canvas");
    await fill("Canvas name", "Spare canvas");
    await clickText("Create canvas");
    await click(".session-row");
    await click("#workspace-menu");
    await clickText("Move to canvas");
    await clickText("QA canvas");
    await until("live canvas tile", () => find(".tile .xterm-screen"));
    await marker("canvas");
  });
  await check("Resize, move, and zoom canvas", async () => {
    await click('[aria-label="Resize QA shell"]');
    await keys("\uE014");
    assert.equal(
      await inspect("return document.querySelector('.tile').style.width"),
      "576px",
    );
    const header = await find(".tile header");
    await command("POST", "/actions", {
      actions: [
        {
          type: "pointer",
          id: "mouse",
          parameters: { pointerType: "mouse" },
          actions: [
            {
              type: "pointerMove",
              duration: 0,
              origin: { "element-6066-11e4-a52e-4f735466cecf": header },
              x: 0,
              y: 0,
            },
            { type: "pointerDown", button: 0 },
            {
              type: "pointerMove",
              duration: 300,
              origin: "pointer",
              x: 64,
              y: 40,
            },
            { type: "pointerUp", button: 0 },
          ],
        },
      ],
    });
    assert.equal(
      await inspect("return document.querySelector('.tile').style.left"),
      "96px",
    );
    await click("#workspace-menu");
    await clickText("Zoom out");
    assert.equal(
      await inspect(
        "return document.querySelector('.canvas-viewport').getAttribute('aria-label')",
      ),
      "QA canvas, 90%",
    );
    assert.equal(
      await inspect(
        "return document.querySelectorAll('.tile .terminal-surface').length",
      ),
      0,
    );
    await click("#workspace-menu");
    await clickText("Actual size (100%)");
    await marker("after_zoom");
    assert.equal(
      await inspect(
        "return getComputedStyle(document.querySelector('.tile header')).height",
      ),
      "30px",
    );
    assert.equal(
      await inspect(
        "return document.querySelector('#toolbar').getBoundingClientRect().height",
      ),
      0,
    );
    assert.equal(
      await inspect(
        "return getComputedStyle(document.querySelector('.canvas-viewport')).backgroundSize",
      ),
      "64px 64px",
    );
    await screenshot("canvas");
    await keys("exit\uE007");
    await until("canvas reports process exit", () =>
      inspect(
        "return document.querySelector('.tile .session-status')?.textContent === 'ended'",
      ),
    );
    await click('[aria-label="Focus QA shell"]');
    await clickText("Restart");
    await running();
  });
  await check("Cancel close keeps terminal usable", async () => {
    await click("#workspace-menu");
    await clickText("Close");
    await clickText("Cancel");
    await marker("cancel_close", false);
  });
  await check("Exit and restart terminal", async () => {
    await keys("exit\uE007");
    await ended();
    await clickText("Restart");
    await running();
    await marker("restart", false);
    await keys("exit\uE007");
    await ended();
  });
  await check("Keyboard search launches saved preset", async () => {
    await command("POST", "/actions", {
      actions: [
        {
          type: "key",
          id: "keyboard",
          actions: [
            { type: "keyDown", value: "\uE009" },
            { type: "keyDown", value: "\uE008" },
            { type: "keyDown", value: "p" },
            { type: "keyUp", value: "p" },
            { type: "keyUp", value: "\uE008" },
            { type: "keyUp", value: "\uE009" },
          ],
        },
      ],
    });
    await fill("Search workspace", "Daily shell");
    await keys("\uE007");
    await running();
    await marker("search_launch", false);
    await screenshot("preset-launch");
    await keys("exit\uE007");
    await ended();
  });
  await check(
    "Saved workspace survives app restart without executing sessions",
    async () => {
      await until("workspace saved", async () => {
        const saved = JSON.parse(
          await readFile(join(support, "workspace.json"), "utf8"),
        );
        return (
          saved.instances.length === 2 &&
          saved.launchPresets.length === 1 &&
          saved.canvases[0].tiles[0].size[0] === 576
        );
      });
      await command("DELETE", "");
      session = undefined;
      await openApp();
      assert.equal(
        await inspect(
          "return document.querySelectorAll('.terminal-surface').length",
        ),
        0,
      );
      assert.equal(
        await inspect(
          "return document.querySelectorAll('.session-row[aria-label$=\"Ready to open\"]').length",
        ),
        2,
      );
      await screenshot("restored-workspace");
      await clickText("Open session");
      await running();
      await marker("restored", false);
      await keys("exit\uE007");
      await ended();
    },
  );
  await check(
    "Canvas double-click launch and detach preserve the live process",
    async () => {
      await click(".canvas-row");
      const viewport = await find(".canvas-viewport");
      const rect = await inspect(
        "return document.querySelector('.canvas-viewport').getBoundingClientRect().toJSON()",
      );
      await command("POST", "/actions", {
        actions: [
          {
            type: "pointer",
            id: "mouse",
            parameters: { pointerType: "mouse" },
            actions: [
              {
                type: "pointerMove",
                duration: 0,
                origin: { "element-6066-11e4-a52e-4f735466cecf": viewport },
                x: Math.round(-rect.width / 2 + 24),
                y: Math.round(-rect.height / 2 + 24),
              },
              { type: "pointerDown", button: 0 },
              { type: "pointerUp", button: 0 },
              { type: "pointerDown", button: 0 },
              { type: "pointerUp", button: 0 },
            ],
          },
        ],
      });
      await click(".advanced-launch summary");
      await fill("Name", "Canvas launch");
      await fill(
        "Shell executable",
        windows ? "C:\\Windows\\System32\\cmd.exe" : "/bin/sh",
      );
      await fill("Working folder", project);
      await fill("Arguments", windows ? "/Q /D" : "");
      await clickText("Open terminal");
      await until("new terminal placed on original canvas", () =>
        inspect("return document.querySelectorAll('.tile').length === 2"),
      );
      await click('[aria-label="Remove Canvas launch from canvas"]');
      await running();
      await marker("detached", false);
      assert.equal(
        await inspect(
          "return document.querySelector('#toolbar').getBoundingClientRect().height",
        ),
        0,
      );
      await keys("exit\uE007");
      await ended();
    },
  );
  assert.equal(
    await inspect("return document.querySelector('#notice').hidden"),
    true,
    "No unexpected application errors",
  );
  evidence.success = true;
} catch (error) {
  evidence.error = error.stack;
  console.error(error);
  if (!windows) {
    // This is the isolated Xvfb desktop, including failures before WebDriver
    // has a session. It never captures the developer's host desktop.
    spawnSync(
      "import",
      ["-window", "root", join(resultDir, "startup-desktop.png")],
      { timeout: 5_000 },
    );
    const windows = spawnSync("xwininfo", ["-root", "-tree"], {
      timeout: 5_000,
      encoding: "utf8",
    });
    await writeFile(join(resultDir, "x11-windows.txt"), windows.stdout ?? "");
    if (!session && process.env.GITHUB_ACTIONS === "true") {
      for (const pid of await readdir("/proc")) {
        if (!/^\d+$/.test(pid)) continue;
        if (
          (await readlink(`/proc/${pid}/exe`).catch(() => "")) !== application
        )
          continue;
        // Stack only, from our test app on the disposable runner. Never dump
        // memory, locals, or credentials, and never request a password.
        const trace = spawnSync(
          "sudo",
          [
            "-n",
            "gdb",
            "--batch",
            "-ex",
            "set pagination off",
            "-ex",
            "thread 1",
            "-ex",
            "bt 20",
            "-p",
            pid,
          ],
          { timeout: 10_000, encoding: "utf8" },
        );
        await writeFile(
          join(resultDir, "startup-stack.txt"),
          (trace.stdout ?? "") + (trace.stderr ?? ""),
        );
      }
    }
  }
  if (session) {
    await screenshot("failure").catch(() => {});
    const dom = await inspect("return document.body.innerText").catch(String);
    await writeFile(join(resultDir, "failure-dom.txt"), String(dom));
  }
  process.exitCode = 1;
} finally {
  if (session) await command("DELETE", "").catch(() => {});
  // Killing only tauri-driver leaves Linux descendants holding these pipes
  // open after startup failure, keeping Node alive until the CI timeout.
  if (!windows && driver.pid) {
    try {
      process.kill(-driver.pid, "SIGTERM");
    } catch {
      /* Already exited. */
    }
  } else driver.kill();
  driver.stdout.destroy();
  driver.stderr.destroy();
  driver.unref();
  await writeFile(join(resultDir, "driver.log"), driverLog);
  await writeFile(
    join(resultDir, "results.json"),
    JSON.stringify(evidence, null, 2),
  );
}

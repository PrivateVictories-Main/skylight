import { Channel, invoke } from "@tauri-apps/api/core";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebglAddon } from "@xterm/addon-webgl";
import type { Instance } from "./model";
import "@xterm/xterm/css/xterm.css";

export class TerminalSession {
  readonly element = document.createElement("div");
  readonly terminal: Terminal;
  private readonly fit = new FitAddon();
  private readonly observer: ResizeObserver;
  private gpu?: WebglAddon;
  private frame = 0;
  private visible = false;
  private disposed = false;
  private through = 0;
  private input = Promise.resolve();
  private queuedInput = 0;
  state: "opening" | "running" | "ended" | "error" = "opening";
  constructor(
    readonly instance: Instance,
    private changed: () => void,
    private report: (error: unknown) => void,
  ) {
    this.element.className = "terminal-surface";
    this.terminal = new Terminal({
      fontFamily: "'Skylight Mono', monospace",
      fontSize: 14,
      lineHeight: 1.15,
      cursorBlink: false,
      scrollback: 3000,
      allowProposedApi: false,
      theme: {
        background: "#212121",
        foreground: "#d8d8d8",
        cursor: "#d8d8d8",
        selectionBackground: "#ffffff33",
        black: "#262830",
        red: "#ec8791",
        green: "#a6d8ac",
        yellow: "#e9cf8e",
        blue: "#9cbbf3",
        magenta: "#c6a3ed",
        cyan: "#9cdad8",
        white: "#e2e4e9",
      },
    });
    this.terminal.loadAddon(this.fit);
    this.terminal.open(this.element);
    this.terminal.onData((data) => this.send(new TextEncoder().encode(data)));
    this.terminal.onBinary((data) =>
      this.send(Uint8Array.from(data, (ch) => ch.charCodeAt(0) & 255)),
    );
    this.observer = new ResizeObserver(() => this.scheduleFit());
    this.observer.observe(this.element);
  }
  async start(program: string, cwd: string | null): Promise<void> {
    const output = new Channel<ArrayBuffer>();
    output.onmessage = (buffer) => {
      if (this.disposed) return;
      const bytes = new Uint8Array(buffer);
      if (bytes[0] === 0) {
        this.terminal.write(bytes.subarray(1), () => {
          this.through += bytes.byteLength - 1;
          void invoke("acknowledge_output", {
            id: this.instance.id,
            through: this.through,
          }).catch((error) => {
            if (this.state === "running") this.report(error);
          });
        });
      } else if (bytes[0] === 1) {
        this.state = "ended";
        const code = new DataView(buffer).getUint32(1, true);
        this.terminal.writeln(
          `\r\n\x1b[90mSession ended${code === 0xffffffff ? "" : ` · exit ${code}`}\x1b[0m`,
        );
        this.changed();
      } else if (bytes[0] === 2) {
        this.report(new TextDecoder().decode(bytes.subarray(1)));
      }
    };
    try {
      await invoke("start_session", {
        id: this.instance.id,
        request: {
          program,
          arguments: this.instance.spec.arguments,
          cwd,
          columns: this.terminal.cols,
          rows: this.terminal.rows,
        },
        output,
      });
      if (this.state === "opening") this.state = "running";
      this.scheduleFit();
      this.changed();
    } catch (error) {
      this.state = "error";
      this.changed();
      throw error;
    }
  }
  private send(bytes: Uint8Array): void {
    if (this.state !== "running") return;
    if (this.queuedInput + bytes.length > 1024 * 1024) {
      this.report(
        "The input queue is full. Wait for the terminal before pasting again.",
      );
      return;
    }
    this.queuedInput += bytes.length;
    this.input = this.input.then(async () => {
      try {
        for (let offset = 0; offset < bytes.length; offset += 8192) {
          if (this.disposed) return;
          await invoke("terminal_input", {
            id: this.instance.id,
            data: Array.from(bytes.subarray(offset, offset + 8192)),
          });
        }
      } catch (error) {
        this.report(error);
      } finally {
        this.queuedInput -= bytes.length;
      }
    });
  }
  setVisible(visible: boolean, focus = false): void {
    this.visible = visible;
    if (visible) {
      if (!this.gpu) {
        try {
          const gpu = new WebglAddon();
          gpu.onContextLoss(() => {
            gpu.dispose();
            this.gpu = undefined;
          });
          this.terminal.loadAddon(gpu);
          this.gpu = gpu;
        } catch {
          /* The built-in renderer remains fully usable without WebGL. */
        }
      }
      this.scheduleFit();
      if (focus) this.terminal.focus();
    } else {
      this.gpu?.dispose();
      this.gpu = undefined;
    }
  }
  private scheduleFit(): void {
    if (!this.visible || this.frame || this.disposed) return;
    this.frame = requestAnimationFrame(() => {
      this.frame = 0;
      if (
        !this.visible ||
        !this.element.isConnected ||
        this.element.clientWidth < 2 ||
        this.element.clientHeight < 2
      )
        return;
      const before = [this.terminal.cols, this.terminal.rows];
      this.fit.fit();
      if (
        this.state === "running" &&
        (before[0] !== this.terminal.cols || before[1] !== this.terminal.rows)
      ) {
        void invoke("resize_terminal", {
          id: this.instance.id,
          columns: this.terminal.cols,
          rows: this.terminal.rows,
        }).catch(this.report);
      }
    });
  }
  async close(): Promise<void> {
    await invoke("close_session", { id: this.instance.id });
    this.dispose();
  }
  dispose(): void {
    this.disposed = true;
    this.observer.disconnect();
    cancelAnimationFrame(this.frame);
    this.gpu?.dispose();
    this.terminal.dispose();
    this.element.remove();
  }
}

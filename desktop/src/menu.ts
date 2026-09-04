export interface MenuAction {
  label: string;
  run: () => void | Promise<void>;
  id?: string;
}

let dismiss: (() => void) | undefined;

/** Contextual commands share one keyboard-accessible surface. Opening a menu
 * never mounts, restarts, or steals ownership of a terminal session. */
export function showMenu(
  actions: MenuAction[],
  anchor: { x: number; y: number },
  report: (error: unknown) => void,
): void {
  dismiss?.();
  const previous = document.activeElement as HTMLElement | null;
  const menu = document.createElement("div");
  menu.className = "command-menu";
  menu.setAttribute("role", "menu");
  menu.setAttribute("aria-label", "Workspace commands");
  const close = (restore = true) => {
    menu.remove();
    document.removeEventListener("pointerdown", outside, true);
    window.removeEventListener("blur", dismissMenu);
    if (dismiss === dismissMenu) dismiss = undefined;
    if (restore && previous?.isConnected) previous.focus();
  };
  const dismissMenu = () => close();
  const outside = (event: PointerEvent) => {
    if (!menu.contains(event.target as Node)) close(false);
  };
  for (const action of actions) {
    const item = document.createElement("button");
    item.type = "button";
    item.textContent = action.label;
    item.setAttribute("role", "menuitem");
    item.tabIndex = -1;
    if (action.id) item.id = action.id;
    item.onclick = () => {
      close();
      Promise.resolve().then(action.run).catch(report);
    };
    menu.append(item);
  }
  menu.onkeydown = (event) => {
    const items = [...menu.querySelectorAll("button")];
    const current = items.indexOf(document.activeElement as HTMLButtonElement);
    const direction = event.key === "ArrowDown" ? 1 : -1;
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      items[(current + direction + items.length) % items.length]?.focus();
    } else if (event.key === "Home" || event.key === "End") {
      event.preventDefault();
      items[event.key === "Home" ? 0 : items.length - 1]?.focus();
    } else if (event.key === "Escape" || event.key === "Tab") {
      event.preventDefault();
      close();
    }
  };
  document.body.append(menu);
  const bounds = menu.getBoundingClientRect();
  menu.style.left = `${Math.max(8, Math.min(anchor.x, innerWidth - bounds.width - 8))}px`;
  menu.style.top = `${Math.max(8, Math.min(anchor.y, innerHeight - bounds.height - 8))}px`;
  document.addEventListener("pointerdown", outside, true);
  window.addEventListener("blur", dismissMenu);
  dismiss = dismissMenu;
  menu.querySelector("button")?.focus();
}

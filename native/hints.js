// SPDX-License-Identifier: GPL-3.0-or-later
// Invoked by trusted Emacs commands; no page-to-native binding is installed.
(function (alphabet, session, mode) {
  "use strict";
  mode = mode || "activate";
  window.__emacsWebHints?.clear();
  function parent(element) {
    return element.parentElement || element.getRootNode().host || null;
  }
  function unavailable(element) {
    if (!element.isConnected || element.matches(":disabled, input[type=hidden]")) return true;
    for (let node = element; node; node = parent(node)) {
      if (node.inert || node.getAttribute("aria-disabled")?.toLowerCase() === "true") return true;
    }
    return false;
  }
  function editable(element) {
    return element.isContentEditable || element.matches("textarea") ||
      (element.matches("input") &&
       !["button", "checkbox", "color", "file", "hidden", "image", "radio", "reset", "submit"].includes(element.type));
  }
  function kind(element) {
    if (unavailable(element) || (editable(element) && element.readOnly)) return null;
    if (element.matches("a[href], area[href], button, input, textarea, select, summary")) return "native";
    if (element.isContentEditable && !parent(element)?.isContentEditable) return "native";
    if (element.matches("label") && element.control && !unavailable(element.control)) return "label";
    const roles = ["button", "link", "tab", "checkbox", "radio", "switch", "menuitem",
                   "menuitemcheckbox", "menuitemradio", "textbox", "combobox", "option", "slider", "spinbutton", "treeitem"];
    if (roles.includes(element.getAttribute("role")?.toLowerCase()) ||
        element.hasAttribute("onclick") || typeof element.onclick === "function" ||
        element.hasAttribute("ng-click") || element.hasAttribute("data-ng-click")) return "control";
    // Event listeners registered with addEventListener are not enumerable.
    // Focusability and a pointer cursor cover common custom JS controls.
    if (element.tabIndex >= 0 || getComputedStyle(element).cursor === "pointer") return "heuristic";
    return null;
  }
  function hitAt(x, y) {
    let hit = document.elementFromPoint(x, y);
    while (hit?.shadowRoot) {
      const inner = hit.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === hit) break;
      hit = inner;
    }
    return hit;
  }
  function contains(element, child) {
    for (let node = child; node; node = parent(node)) if (node === element) return true;
    return false;
  }
  function position(element) {
    if (unavailable(element) || !element.checkVisibility({checkOpacity: true, checkVisibilityCSS: true})) return null;
    for (const rect of element.getClientRects()) {
      const left = Math.max(0, rect.left), top = Math.max(0, rect.top);
      const right = Math.min(innerWidth, rect.right), bottom = Math.min(innerHeight, rect.bottom);
      if (right - left < 2 || bottom - top < 2) continue;
      const points = [[(left + right) / 2, (top + bottom) / 2],
                      [left + 1, top + 1], [right - 1, bottom - 1]];
      for (const [x, y] of points) {
        if (contains(element, hitAt(x, y))) return {left, top, x, y};
      }
    }
    return null;
  }
  let entries = [];
  const roots = [document];
  for (let index = 0; index < roots.length; index++) {
    for (const element of roots[index].querySelectorAll("*")) {
      if (element.shadowRoot) roots.push(element.shadowRoot);
      if (mode !== "activate" && (!element.matches("a[href], area[href]") || typeof element.href !== "string")) continue;
      if (mode === "queue" && !/^(https?|file):/i.test(element.href)) continue;
      const type = kind(element);
      if (!type) continue;
      const point = position(element);
      if (point) entries.push({element, type, ...point});
    }
  }
  const candidates = new Map(entries.map(entry => [entry.element, entry]));
  const labelledControls = new Set();
  entries = entries.filter(entry => {
    if (entry.type === "label") {
      if (candidates.has(entry.element.control) || labelledControls.has(entry.element.control)) return false;
      labelledControls.add(entry.element.control);
    }
    // A native button/link/editor owns its contents, including descendants
    // with role, onclick or tabindex attributes (not just pointer cursors).
    for (let node = parent(entry.element); node; node = parent(node)) {
      if (candidates.get(node)?.type === "native") return false;
    }
    return true;
  });
  // Prefer the actual control to a clickable wrapper.  Do this before
  // dropping inherited pointer cursors, so both candidates cannot disappear.
  entries = entries.filter(entry => entry.type === "native" ||
    !entries.some(other => other !== entry && other.type !== "heuristic" && contains(entry.element, other.element)));
  const owners = new Set(entries.map(entry => entry.element));
  entries = entries.filter(entry => {
    if (entry.type !== "heuristic") return true;
    for (let node = parent(entry.element); node; node = parent(node)) {
      if (owners.has(node)) return false;
    }
    return true;
  });
  entries.sort((a, b) => a.top - b.top || a.left - b.left);
  // Bound the response and overlay work on unusually dense pages.
  entries.splice(1000);
  const host = document.createElement("div");
  host.setAttribute("data-emacs-web-hints", session);
  host.setAttribute("popover", "manual");
  host.style.cssText = "all:initial!important;position:fixed!important;inset:0!important;"
    + "z-index:2147483647!important;pointer-events:none!important;display:block!important;"
    + "margin:0!important;padding:0!important;border:0!important;background:transparent!important;";
  const shadow = host.attachShadow({mode: "open"});
  let width = 1;
  while (alphabet.length ** width < entries.length) width++;
  entries.forEach((entry, index) => {
    let number = index, label = "";
    for (let digit = 0; digit < width; digit++) {
      label = alphabet[number % alphabet.length] + label;
      number = Math.floor(number / alphabet.length);
    }
    const badge = document.createElement("span");
    badge.textContent = label;
    badge.style.cssText = "position:absolute;box-sizing:border-box;background:#ffdf65;color:#161616;"
      + "font:bold 13px/18px monospace;padding:0 3px;border:1px solid #805f00;border-radius:3px;"
      + "box-shadow:0 1px 3px #0008;white-space:nowrap;pointer-events:none;"
      + `left:${Math.min(entry.left, Math.max(0, innerWidth - width * 9 - 8))}px;top:${entry.top}px;`;
    entry.label = label;
    entry.badge = badge;
    shadow.appendChild(badge);
  });
  function onScroll() {
    // A queued scroll event (or scrolling an unrelated panel) need not move
    // any labels.  Only invalidate when their visible geometry really changed.
    if (entries.some(entry => {
      const point = position(entry.element);
      return !point || Math.abs(point.left - entry.left) > 1 || Math.abs(point.top - entry.top) > 1;
    })) clear();
  }
  function clear() {
    host.remove();
    window.removeEventListener("scroll", onScroll, true);
    window.removeEventListener("resize", onScroll);
    if (window.__emacsWebHints?.session === session) delete window.__emacsWebHints;
    return true;
  }
  window.__emacsWebHints = {
    session, clear,
    filter(prefix) {
      for (const entry of entries) entry.badge.hidden = !entry.label.startsWith(prefix);
      return true;
    },
    link(label) {
      const entry = entries.find(entry => entry.label === label);
      if (!entry || !entry.element.matches("a[href], area[href]")) return null;
      const point = position(entry.element);
      if (!point || (mode === "queue" && !/^(https?|file):/i.test(entry.element.href))) return null;
      return {url: entry.element.href, x: point.x, y: point.y};
    },
    prepare(label) {
      const entry = entries.find(entry => entry.label === label);
      if (!entry || !kind(entry.element)) return null;
      const point = position(entry.element);
      if (!point) return null;
      const element = entry.element;
      clear();
      if (editable(element) || element.matches("select")) {
        element.focus({preventScroll: true});
        // Preserve a saved caret; start at the end for single-line text fields.
        if (!(element.matches("textarea") && element.value.includes("\n"))) {
          try {
            if (element.selectionStart === 0 && element.selectionEnd === 0)
              element.setSelectionRange(element.value.length, element.value.length);
          } catch (_) { /* Some input types have no text selection API. */ }
        }
        return {action: "focus"};
      }
      // The host sends an actual Chromium mouse click at this verified point.
      // That preserves event handlers, preventDefault and user activation.
      return {action: "click", x: point.x, y: point.y,
              link: element.matches("a[href], area[href]") && /^(https?|file):/i.test(element.href)};
    }
  };
  if (entries.length) {
    document.documentElement.appendChild(host);
    // Top-layer dialogs cannot be covered by a z-index alone.
    host.showPopover();
  }
  window.addEventListener("scroll", onScroll, true);
  window.addEventListener("resize", onScroll);
  return JSON.stringify(entries.map(entry => ({
    label: entry.label, url: typeof entry.element.href === "string" ? entry.element.href : null,
    tag: entry.element.localName,
    title: (entry.element.getAttribute("aria-label") || entry.element.textContent ||
            entry.element.getAttribute("placeholder") || entry.element.getAttribute("name") || "").trim().slice(0, 120)
  })));
})

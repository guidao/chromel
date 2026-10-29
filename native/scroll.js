// SPDX-License-Identifier: GPL-3.0-or-later
// Executed in the focused CEF frame, never through cross-origin DOM access.
(function (delta, duration, mode) {
  "use strict";
  mode = mode || "pixels";
  // A zero-distance invocation installs tracking at document start in every
  // frame.  The first click must be remembered even before the first j/k.
  if (!window.__emacsWebScroller) {
    const animations = new Map();
    let pending = 0, activated = null;
    const parent = element => element.assignedSlot || element.parentElement || element.getRootNode().host;
    const limit = element => Math.max(0, element.scrollHeight - element.clientHeight);
    function contains(ancestor, child) {
      for (let node = child; node; node = parent(node)) if (node === ancestor) return true;
      return false;
    }
    function elements(root) {
      const result = [], roots = [root];
      for (let index = 0; index < roots.length; index++) {
        for (const element of roots[index].querySelectorAll("*")) {
          result.push(element);
          if (element.shadowRoot) roots.push(element.shadowRoot);
        }
      }
      return result;
    }
    function visible(element) {
      if (!element.isConnected || !element.checkVisibility({checkVisibilityCSS: true})) return false;
      for (let node = element; node; node = parent(node)) if (node.inert) return false;
      const rect = element.getBoundingClientRect();
      return rect.bottom > 0 && rect.right > 0 && rect.top < innerHeight && rect.left < innerWidth;
    }
    function exposed(element) {
      if (!visible(element)) return false;
      const rect = element.getBoundingClientRect();
      const left = Math.max(0, rect.left), right = Math.min(innerWidth, rect.right);
      const top = Math.max(0, rect.top), bottom = Math.min(innerHeight, rect.bottom);
      if (right <= left || bottom <= top) return false;
      for (const [x,y] of [[(left+right)/2,(top+bottom)/2], [left+1,top+1], [right-1,bottom-1]]) {
        let hit = document.elementFromPoint(x,y);
        while (hit?.shadowRoot) {
          const inner = hit.shadowRoot.elementFromPoint(x,y);
          if (!inner || inner === hit) break;
          hit = inner;
        }
        if (contains(element, hit)) return true;
      }
      return false;
    }
    function scope() {
      // Native dialogs/popovers and semantic modal overlays take precedence
      // over a previously clicked element underneath them.
      const roots = new Set([document, activated?.getRootNode(), document.activeElement?.shadowRoot]);
      const layers = [...roots].filter(root => root?.querySelectorAll).flatMap(root =>
        [...root.querySelectorAll('dialog[open], :popover-open, [role="dialog"], [role="alertdialog"]')]
      ).filter(element => !element.hasAttribute("data-emacs-web-hints") && exposed(element));
      return layers.reverse().find(element => element.matches(':modal, :popover-open')) ||
        layers[0] || document.documentElement;
    }
    function scrollable(element, amount) {
      if (element !== document.scrollingElement && !exposed(element)) return false;
      const overflow = getComputedStyle(element).overflowY;
      if (element === document.scrollingElement ? /^(hidden|clip)$/.test(overflow) : !/^(auto|scroll|overlay)$/.test(overflow)) return false;
      // Body overflow can be propagated to the viewport.  Long content under
      // a modal is not evidence that the locked document can actually scroll.
      if (element === document.scrollingElement && overflow === "visible" && document.body &&
          /^(hidden|clip)$/.test(getComputedStyle(document.body).overflowY)) return false;
      // Use the current position while an animation reaches the boundary;
      // queued keystrokes must not start moving the outer document too early.
      if (limit(element) <= 0) return false;
      if (animations.has(element)) return true;
      // Verify movement as Vimium does; dimensions alone can describe a
      // clipped or non-scrollable box.  Restore immediately after the probe.
      const before = element.scrollTop;
      element.scrollBy({top: Math.sign(amount), behavior: "instant"});
      const moved = element.scrollTop !== before;
      element.scrollTo({top: before, behavior: "instant"});
      return moved;
    }
    function target(amount, absolute = false) {
      const canScroll = element => scrollable(element, amount) ||
        (absolute && scrollable(element, -amount));
      const boundary = scope();
      let focused = document.activeElement;
      while (focused?.shadowRoot?.activeElement) focused = focused.shadowRoot.activeElement;
      // The clicked text can move off screen during scrolling; retain its
      // visible scroll-container ancestor instead of losing the activation.
      function visibleAncestor(element) {
        if (!element || !contains(boundary, element) ||
            !element.checkVisibility({checkVisibilityCSS: true})) return null;
        for (let node = element; node; node = parent(node)) {
          if (exposed(node)) return node;
          if (node === boundary) break;
        }
        return null;
      }
      const start = visibleAncestor(activated) || visibleAncestor(focused) || boundary;
      for (let element = start; element; element = parent(element)) {
        if (canScroll(element)) return element;
        if (element === boundary) break;
      }
      const root = document.scrollingElement;
      if (boundary === document.documentElement && root) {
        if (canScroll(root)) return root;
        // A usable document at its boundary should not jump into another
        // panel.  A locked document must still search its visible overlay.
        if (scrollable(root, -amount)) return null;
      }
      let best = null, area = 0;
      for (const element of elements(boundary)) {
          if (!canScroll(element)) continue;
          const rect = element.getBoundingClientRect();
          const size = Math.max(0, Math.min(innerWidth, rect.right) - Math.max(0, rect.left)) *
                       Math.max(0, Math.min(innerHeight, rect.bottom) - Math.max(0, rect.top));
          if (size > area) { area = size; best = element; }
      }
      return best;
    }
    function cancel() {
      cancelAnimationFrame(pending);
      pending = 0;
      animations.clear();
    }
    function animate(time) {
      pending = 0;
      for (const [element, state] of animations) {
        if (!element.isConnected) { animations.delete(element); continue; }
        state.end = Math.min(state.end, limit(element));
        const distance = state.end - element.scrollTop;
        const elapsed = Math.max(0, Math.min(64, time - state.time));
        const step = Math.abs(distance) * (1 - Math.exp(-elapsed / (state.duration / 4)));
        const next = element.scrollTop + Math.sign(distance) * Math.min(Math.abs(distance), Math.max(1, step));
        state.time = time;
        element.scrollTo({top: next, behavior: "instant"});
        // Chromium may round scroll offsets; snap the final pixel exactly.
        if (Math.abs(state.end - element.scrollTop) <= 1) {
          element.scrollTo({top: state.end, behavior: "instant"});
          animations.delete(element);
        }
      }
      if (animations.size) pending = requestAnimationFrame(animate);
    }
    window.addEventListener("wheel", cancel, {capture: true, passive: true});
    window.addEventListener("touchstart", cancel, {capture: true, passive: true});
    window.addEventListener("pointerdown", event => {
      cancel();
      activated = event.composedPath()[0];
    }, true);
    window.addEventListener("focusin", event => { activated = event.composedPath()[0]; }, true);
    window.addEventListener("click", event => { activated = event.composedPath()[0]; }, true);
    window.addEventListener("pagehide", cancel);
    window.__emacsWebScroller = {
      reset() { cancel(); activated = null; },
      scroll(amount, milliseconds, mode = "pixels") {
        const absolute = mode === "top" || mode === "bottom";
        const element = target(amount, absolute);
        if (!element) return;
        if (mode === "half") amount *= Math.max(1, Math.round(element.clientHeight / 2));
        const previous = animations.get(element);
        const base = previous && Math.sign(previous.end - element.scrollTop) === Math.sign(amount) ?
          previous.end : element.scrollTop;
        const end = mode === "top" ? 0 : mode === "bottom" ? limit(element) :
          Math.max(0, Math.min(limit(element), base + amount));
        if (!milliseconds || matchMedia("(prefers-reduced-motion: reduce)").matches) {
          animations.delete(element);
          element.scrollTo({top: end, behavior: "instant"});
          return;
        }
        // Extend a shared target instead of restarting the browser's native
        // smooth-scroll animation on every key repeat.  Reversals start from
        // the current position, dropping the old direction's queued distance.
        animations.set(element, {end, duration: milliseconds, time: previous?.time ?? performance.now()});
        if (!pending) pending = requestAnimationFrame(animate);
      }
    };
  }
  if (Number.isFinite(delta) && delta) window.__emacsWebScroller.scroll(delta, duration, mode);
})

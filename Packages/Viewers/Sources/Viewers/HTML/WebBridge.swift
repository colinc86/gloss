import Foundation

/// The script the app injects into every page, in the `.defaultClient` world where page scripts cannot see it.
/// It reports the selection, paints note highlights (CSS custom highlights for text, an overlay for elements),
/// scrolls to notes, says when the page's text or URL changes, serialises the page for the source view, and in
/// note mode lets the user pick an element.
///
/// Nothing here adds a text node to the page: the overlay's boxes are empty elements labelled through
/// `data-label`, so `textContent` offsets stay those of the source.
enum WebBridge {
    static let handlerName = "gloss"

    static let script = """
    (() => {
      const post = (message) => window.webkit.messageHandlers.gloss.postMessage(message);
      const root = () => document.documentElement;
      const OVERLAY = 'gloss-overlay';
      let overlay = null;
      const inOverlay = (node) => { for (let n = node; n; n = n.parentNode) { if (n.nodeType === 1 && n.tagName && n.tagName.toLowerCase() === OVERLAY) return true; } return false; };

      // MARK: Text offsets (the overlay holds no text, so it never shifts them).
      function textNodes() {
        const walker = document.createTreeWalker(root(), NodeFilter.SHOW_TEXT);
        const nodes = [];
        let node;
        while ((node = walker.nextNode())) nodes.push(node);
        return nodes;
      }
      function offsetOf(container, offset) {
        const before = document.createRange();
        before.selectNodeContents(root());
        before.setEnd(container, offset);
        return before.toString().length;
      }
      function rangeAt(start, end) {
        const range = document.createRange();
        let position = 0, started = false;
        for (const node of textNodes()) {
          const length = node.data.length;
          if (!started && start <= position + length) { range.setStart(node, start - position); started = true; }
          if (started && end <= position + length) { range.setEnd(node, end - position); return range; }
          position += length;
        }
        return null;
      }

      // MARK: Selection
      let timer = null;
      function report() {
        const selection = getSelection();
        if (!selection || selection.rangeCount === 0 || selection.isCollapsed) { post({}); return; }
        const range = selection.getRangeAt(0);
        const text = range.toString();
        const box = range.getBoundingClientRect();
        post({ start: offsetOf(range.startContainer, range.startOffset), length: text.length, text,
               x: box.left, y: box.top, w: box.width, h: box.height });
      }
      document.addEventListener('selectionchange', () => { clearTimeout(timer); timer = setTimeout(report, 60); });
      window.addEventListener('scroll', () => { if (!getSelection().isCollapsed) { clearTimeout(timer); timer = setTimeout(report, 60); } relayout(); }, { passive: true });
      window.addEventListener('resize', relayout);

      // MARK: Changes. Page scripts may rewrite the text or the route; the app re-aligns once they settle.
      let changeTimer = null;
      let lastURL = location.href;
      function reportURL() { if (location.href !== lastURL) { lastURL = location.href; post({ url: lastURL }); } }
      new MutationObserver((records) => {
        if (records.every((r) => inOverlay(r.target))) return;
        clearTimeout(changeTimer);
        changeTimer = setTimeout(() => { reportURL(); post({ changed: true }); relayout(); }, 200);
      }).observe(root(), { childList: true, characterData: true, subtree: true });
      window.addEventListener('popstate', reportURL);
      window.addEventListener('hashchange', reportURL);

      // MARK: Serialisation for the source view (the overlay is left out).
      function textHash() {
        let h = 2166136261;
        const text = root().textContent;
        for (let i = 0; i < text.length; i++) { h ^= text.charCodeAt(i); h = Math.imul(h, 16777619) >>> 0; }
        return h.toString(16) + ':' + text.length;
      }
      function serialize() {
        const parent = overlay && overlay.parentNode;
        if (parent) parent.removeChild(overlay);
        const html = root().outerHTML;
        const text = root().textContent;
        if (parent) parent.appendChild(overlay);
        return { html, text, textHash: textHash() };
      }

      // MARK: Selectors and descriptions
      const esc = (s) => (window.CSS && CSS.escape) ? CSS.escape(s) : s.replace(/[^a-zA-Z0-9_-]/g, (c) => '\\\\' + c);
      const unique = (selector) => { try { return document.querySelectorAll(selector).length === 1; } catch (e) { return false; } };
      function step(el) {
        const tag = el.tagName.toLowerCase();
        const siblings = el.parentElement ? Array.from(el.parentElement.children).filter((c) => c.tagName === el.tagName) : [el];
        return siblings.length > 1 ? tag + ':nth-of-type(' + (siblings.indexOf(el) + 1) + ')' : tag;
      }
      function anchorFor(el) {
        if (el.id && unique('#' + esc(el.id))) return '#' + esc(el.id);
        const testID = el.getAttribute && el.getAttribute('data-testid');
        if (testID) { const s = '[data-testid="' + testID.replace(/"/g, '\\\\"') + '"]'; if (unique(s)) return s; }
        return null;
      }
      function selectorFor(el) {
        const parts = [];
        let node = el, base = null;
        while (node && node.nodeType === 1 && node !== root()) {
          const anchor = anchorFor(node);
          if (anchor && (node !== el || parts.length === 0)) { base = anchor; if (node === el) return anchor; break; }
          parts.unshift(step(node));
          node = node.parentElement;
        }
        if (!base) parts.unshift('html');
        let selector = (base ? base + ' > ' : '') + parts.join(' > ');
        if (unique(selector)) return selector;
        // Force a position on every segment so the path names exactly one element.
        const forced = [];
        node = el;
        while (node && node.nodeType === 1 && node !== root()) {
          const anchor = anchorFor(node);
          if (anchor && node !== el) { forced.unshift(anchor); break; }
          const tag = node.tagName.toLowerCase();
          const siblings = node.parentElement ? Array.from(node.parentElement.children).filter((c) => c.tagName === node.tagName) : [node];
          forced.unshift(tag + ':nth-of-type(' + (siblings.indexOf(node) + 1) + ')');
          node = node.parentElement;
        }
        if (!node || node === root()) forced.unshift('html');
        return forced.join(' > ');
      }
      const collapse = (s) => s.replace(/\\s+/g, ' ').trim();
      function describe(el) {
        const box = el.getBoundingClientRect();
        let textOffset = null;
        const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
        let first;
        while ((first = walker.nextNode())) { if (first.data.trim().length) { textOffset = offsetOf(first, 0); break; } }
        return { selector: selectorFor(el), tag: el.tagName.toLowerCase(), text: collapse(el.textContent || '').slice(0, 500),
                 html: (el.outerHTML || '').slice(0, 2048),
                 rect: { x: box.left, y: box.top, w: box.width, h: box.height },
                 page: { x: box.left + scrollX, y: box.top + scrollY, w: box.width, h: box.height },
                 textOffset };
      }

      // MARK: Overlay: boxes for element notes and the pick-mode hover, drawn above everything, taking no events.
      const boxes = new Map();
      let hover = null;
      function ensureOverlay() {
        if (overlay && overlay.isConnected) return overlay;
        overlay = document.createElement(OVERLAY);
        overlay.setAttribute('style', 'all:initial;position:absolute;left:0;top:0;width:0;height:0;z-index:2147483647;pointer-events:none;');
        root().appendChild(overlay);
        return overlay;
      }
      function place(box, el) {
        const r = el.getBoundingClientRect();
        box.style.left = (r.left + scrollX) + 'px';
        box.style.top = (r.top + scrollY) + 'px';
        box.style.width = r.width + 'px';
        box.style.height = r.height + 'px';
      }
      function makeBox(color, label, dashed) {
        const box = document.createElement('div');
        box.setAttribute('style', 'all:initial;position:absolute;box-sizing:border-box;border:2px ' + (dashed ? 'dashed' : 'solid') + ' ' + color + ';border-radius:3px;pointer-events:none;');
        if (label) box.setAttribute('data-label', label);
        return box;
      }
      let raf = null;
      function relayout() {
        if (raf) return;
        raf = requestAnimationFrame(() => {
          raf = null;
          for (const [, entry] of boxes) { if (entry.element.isConnected) place(entry.box, entry.element); else entry.box.style.display = 'none'; }
          if (hover) place(hover.box, hover.element);
        });
      }
      function findCandidates(item) {
        let bySelector = null;
        try { const el = document.querySelector(item.selector); if (el && !inOverlay(el)) bySelector = el; } catch (e) {}
        const wanted = collapse(item.text || '');
        const byText = [];
        if (wanted.length) {
          for (const el of document.getElementsByTagName(item.tag)) {
            if (inOverlay(el) || el === bySelector) continue;
            if (collapse(el.textContent || '') === wanted) byText.push(el);
          }
        }
        return { bySelector, byText };
      }
      function resolveElements(list) {
        return list.map((item) => {
          const { bySelector, byText } = findCandidates(item);
          const found = (el) => ({ selector: selectorFor(el), tag: el.tagName.toLowerCase(), text: collapse(el.textContent || '').slice(0, 500),
                                   html: (el.outerHTML || '').slice(0, 2048), rect: (() => { const b = el.getBoundingClientRect(); return { x: b.left + scrollX, y: b.top + scrollY, w: b.width, h: b.height }; })() });
          return { id: item.id, bySelector: bySelector ? found(bySelector) : null, byText: byText.map(found) };
        });
      }
      function highlightElements(list) {
        ensureOverlay();
        for (const [, entry] of boxes) entry.box.remove();
        boxes.clear();
        const rects = {};
        for (const item of list) {
          let el = null;
          try { el = document.querySelector(item.selector); } catch (e) {}
          if (!el || inOverlay(el)) continue;
          const box = makeBox(item.color, item.needsReview ? '?' : null, item.state === 'orphaned');
          box.style.opacity = item.state === 'resolved' ? '0.35' : item.state === 'sent' ? '0.7' : '1';
          box.style.background = item.fill;
          overlay.appendChild(box);
          place(box, el);
          boxes.set(item.id, { box, element: el });
          const r = el.getBoundingClientRect();
          rects[item.id] = { x: r.left, y: r.top, w: r.width, h: r.height };
        }
        return rects;
      }
      function elementRects() {
        const rects = {};
        for (const [id, entry] of boxes) { const r = entry.element.getBoundingClientRect(); rects[id] = { x: r.left, y: r.top, w: r.width, h: r.height }; }
        return rects;
      }
      function scrollToElement(selector) {
        let el = null;
        try { el = document.querySelector(selector); } catch (e) {}
        if (!el) return false;
        el.scrollIntoView({ block: 'center' });
        for (const [, entry] of boxes) {
          if (entry.element === el) { entry.box.animate([{ transform: 'scale(1)' }, { transform: 'scale(1.04)' }, { transform: 'scale(1)' }], { duration: 600 }); }
        }
        relayout();
        return true;
      }

      // MARK: Pick mode
      let picking = false;
      function targetAt(event) {
        const el = document.elementFromPoint(event.clientX, event.clientY);
        return el && !inOverlay(el) && el !== root() && el !== document.body ? el : null;
      }
      function onMove(event) {
        const el = targetAt(event);
        if (!el) { clearHover(); return; }
        if (hover && hover.element === el) return;
        clearHover();
        ensureOverlay();
        const label = el.tagName.toLowerCase() + (el.id ? '#' + el.id : '');
        const box = makeBox('var(--gloss-accent, #0a84ff)', label, false);
        box.style.background = 'rgba(10,132,255,0.10)';
        overlay.appendChild(box);
        place(box, el);
        hover = { box, element: el };
      }
      function clearHover() { if (hover) { hover.box.remove(); hover = null; } }
      function onClick(event) {
        event.preventDefault();
        event.stopPropagation();
        const el = targetAt(event);
        if (el) post({ pick: describe(el) });
      }
      function onKey(event) { if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); post({ pickCancel: true }); } }
      function setPickMode(on) {
        if (on === picking) return;
        picking = on;
        const opts = { capture: true };
        if (on) {
          document.addEventListener('mousemove', onMove, opts);
          document.addEventListener('click', onClick, opts);
          document.addEventListener('mousedown', onClick, opts);
          document.addEventListener('keydown', onKey, opts);
          document.addEventListener('mouseleave', clearHover, opts);
        } else {
          document.removeEventListener('mousemove', onMove, opts);
          document.removeEventListener('click', onClick, opts);
          document.removeEventListener('mousedown', onClick, opts);
          document.removeEventListener('keydown', onKey, opts);
          document.removeEventListener('mouseleave', clearHover, opts);
          clearHover();
        }
      }

      // MARK: Text highlights. A constructed stylesheet adds no text node, so page-text offsets stay those of the source.
      let sheet = null;
      const labelCSS = OVERLAY + ' div[data-label]::after { content: attr(data-label); position: absolute; left: 0; top: -18px; font: 11px -apple-system, sans-serif; color: #fff; background: rgba(10,132,255,0.9); padding: 1px 5px; border-radius: 3px; white-space: nowrap; }\\n';
      window.__cc = {
        highlight(list, css) {
          if (!sheet) { sheet = new CSSStyleSheet(); document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet]; }
          sheet.replaceSync(labelCSS + css);
          if (!window.CSS || !CSS.highlights) return;
          CSS.highlights.clear();
          for (const item of list) {
            const range = rangeAt(item.start, item.end);
            if (range) CSS.highlights.set(item.name, new Highlight(range));
          }
        },
        scrollTo(start, end, select) {
          const range = rangeAt(start, end);
          if (!range) return;
          const element = range.startContainer.parentElement;
          if (element) element.scrollIntoView({ block: 'center' });
          if (select) { const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range); }
        },
        collapse() { const selection = getSelection(); if (selection.rangeCount) selection.collapseToEnd(); },
        serialize, textHash, selectorFor, describe, resolveElements, highlightElements, elementRects, scrollToElement, setPickMode,
        describeAt(selector) { const el = document.querySelector(selector); return el ? describe(el) : null; },
      };
    })();
    """
}

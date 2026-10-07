import Foundation

/// The script the app injects into every page, in the `.defaultClient` world where page scripts cannot see it.
/// It reports the selection, paints note highlights (CSS custom highlights for text, an overlay for elements),
/// scrolls to notes, says when the page's text or URL changes, serialises the page for the source view, lets the
/// user choose a picture or a region of one (a click or a drag, as in Markdown), and in note mode lets the user pick
/// any element.
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
        // Selecting text puts a chosen picture away, as a click elsewhere does.
        if (chosen) clearChosen(true);
        const range = selection.getRangeAt(0);
        const text = range.toString();
        // A page selecting its whole huge body in a loop must not stream megabytes to the app; a note on more
        // than this isn't a selection anyone made by hand.
        if (text.length > 1000000) { post({}); return; }
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
      // The overlay's own comings and goings (it is detached to serialise, attached to draw) are not page changes.
      // The overlay just taken away (no element notes left) counts as ours too.
      let retiredOverlay = null;
      const ours = (r) => inOverlay(r.target)
        || (r.target === root() && (r.addedNodes.length + r.removedNodes.length) > 0
            && [...r.addedNodes, ...r.removedNodes].every((n) => n === overlay || n === retiredOverlay));
      // Reported once changes settle for 200 ms, and at least every 2 s while they never do (a ticking clock, a
      // streaming log), so a page that never rests is still followed.
      let firstChange = 0;
      function reportChange() { firstChange = 0; reportURL(); post({ changed: true }); relayout(); }
      new MutationObserver((records) => {
        if (records.every(ours)) return;
        clearTimeout(changeTimer);
        const now = Date.now();
        if (!firstChange) firstChange = now;
        if (now - firstChange >= 2000) { reportChange(); return; }
        changeTimer = setTimeout(reportChange, 200);
      }).observe(root(), { childList: true, characterData: true, subtree: true });
      window.addEventListener('popstate', reportURL);
      window.addEventListener('hashchange', reportURL);

      // MARK: Serialisation for the source view (the overlay is left out). The hash covers the whole DOM, not only
      // its text, so a renamed id or a moved element counts as a change for the notes anchored to it.
      function fnv(s) {
        let h = 2166136261;
        for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619) >>> 0; }
        return h.toString(16) + ':' + s.length;
      }
      function withoutOverlay(body) {
        const parent = overlay && overlay.parentNode;
        if (parent) parent.removeChild(overlay);
        try { return body(); } finally { if (parent) parent.appendChild(overlay); }
      }
      function textHash() { return withoutOverlay(() => fnv(root().outerHTML)); }
      function serialize() {
        return withoutOverlay(() => { const html = root().outerHTML; return { html, text: root().textContent, textHash: fnv(html) }; });
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
      // Where an element starts in the page's text: its first non-blank text, or for an element without text (an
      // image, an input) the first text after it, so even those map to a source line.
      function textOffsetOf(el) {
        const inside = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
        let node;
        while ((node = inside.nextNode())) { if (node.data.trim().length) return offsetOf(node, 0); }
        const after = document.createTreeWalker(root(), NodeFilter.SHOW_TEXT);
        after.currentNode = el;
        while ((node = after.nextNode())) { if (!inOverlay(node) && node.data.trim().length) return offsetOf(node, 0); }
        return null;
      }
      function describe(el) {
        const box = el.getBoundingClientRect();
        const textOffset = textOffsetOf(el);
        const described = { selector: selectorFor(el), tag: el.tagName.toLowerCase(), text: collapse(el.textContent || '').slice(0, 500),
                 html: (el.outerHTML || '').slice(0, 2048),
                 rect: { x: box.left, y: box.top, w: box.width, h: box.height },
                 page: { x: box.left + scrollX, y: box.top + scrollY, w: box.width, h: box.height },
                 textOffset };
        // A picture says how big it is and where it came from, so the packet can name it.
        if (pictureOf(el) === el) { described.natural = pictureBox(el).natural; described.src = sourceOf(el); }
        return described;
      }
      // A picture's address for the packet: an inline one (data:, blob:) is named, not copied.
      function sourceOf(el) {
        const src = el.currentSrc || el.src;
        if (!src || typeof src !== 'string') return null;
        if (src.startsWith('data:')) return 'data:' + (src.slice(5).split(';')[0].split(',')[0] || 'unknown') + ' (inline)';
        if (src.startsWith('blob:')) return 'blob: (made by the page)';
        return src.slice(0, 2048);
      }

      // MARK: Pictures. An img, an svg, a canvas or a video; a <picture> is its img, an svg's shapes are the svg.
      const PICTURES = ['img', 'svg', 'canvas', 'video'];
      function pictureOf(el) {
        if (!el || el.nodeType !== 1 || inOverlay(el)) return null;
        const tag = el.tagName.toLowerCase();
        if (tag === 'picture') return el.querySelector('img');
        if (el instanceof SVGElement) {
          let svg = el instanceof SVGSVGElement ? el : el.ownerSVGElement;
          while (svg && svg.ownerSVGElement) svg = svg.ownerSVGElement;
          return svg || null;
        }
        return PICTURES.includes(tag) ? el : null;
      }
      // Whether a point is on a character of text: a press there selects text, never a picture behind it.
      function textAt(x, y) {
        const caret = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
        if (!caret || caret.startContainer.nodeType !== 3 || inOverlay(caret.startContainer)) return false;
        const node = caret.startContainer, range = document.createRange();
        for (const at of [caret.startOffset - 1, caret.startOffset]) {
          if (at < 0 || at >= node.data.length) continue;
          range.setStart(node, at); range.setEnd(node, at + 1);
          for (const r of range.getClientRects()) { if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) return true; }
        }
        return false;
      }
      const paints = (el) => {
        const style = getComputedStyle(el), color = style.backgroundColor || '';
        if (style.backgroundImage && style.backgroundImage !== 'none') return true;
        return color.startsWith('rgba(') ? parseFloat(color.slice(color.lastIndexOf(',') + 1)) > 0 : color.startsWith('rgb(');
      };
      // The picture under a point, through the transparent wrappers and links pages lay over pictures; one hidden
      // behind something that paints its own background (a card over a hero image) is not under the point.
      function pictureAt(x, y) {
        if (textAt(x, y)) return null;
        for (const el of document.elementsFromPoint(x, y)) {
          if (inOverlay(el)) continue;
          const picture = pictureOf(el);
          if (picture) return picture;
          if (el === root() || el === document.body) return null;
          if (paints(el)) return null;
        }
        return null;
      }
      // The plain click and drag leave controls alone (an icon in a button, a close ×, an avatar link) and the
      // pictures that are apps of their own (a video's controls, a canvas map); Pick Element still reaches those.
      const CONTROLS = 'button, summary, label, input, select, textarea, [role=button], [role=menuitem], [role=tab], [role=link]';
      function plainPictureAt(x, y) {
        const picture = pictureAt(x, y);
        if (!picture || !['img', 'svg'].includes(picture.tagName.toLowerCase()) || picture.closest(CONTROLS)) return null;
        const r = picture.getBoundingClientRect();
        return r.width < 48 && r.height < 48 ? null : picture;
      }
      const intersect = (a, b) => {
        const x = Math.max(a.x, b.x), y = Math.max(a.y, b.y);
        return { x, y, w: Math.max(0, Math.min(a.x + a.w, b.x + b.w) - x), h: Math.max(0, Math.min(a.y + a.h, b.y + b.h) - y) };
      };
      // Where a picture's pixels are drawn (viewport coordinates), after object-fit and object-position, and the part
      // of that its box shows (cover cuts the rest off). An svg, or a picture that says nothing of its size, is taken
      // at its displayed size.
      function pictureBox(el) {
        const r = el.getBoundingClientRect(), style = getComputedStyle(el);
        const px = (value) => parseFloat(value) || 0;
        const left = px(style.borderLeftWidth) + px(style.paddingLeft), top = px(style.borderTopWidth) + px(style.paddingTop);
        const inner = { x: r.left + left, y: r.top + top,
                        w: Math.max(0, r.width - left - px(style.borderRightWidth) - px(style.paddingRight)),
                        h: Math.max(0, r.height - top - px(style.borderBottomWidth) - px(style.paddingBottom)) };
        const tag = el.tagName.toLowerCase();
        let w = tag === 'img' ? el.naturalWidth : tag === 'video' ? el.videoWidth : tag === 'canvas' ? el.width : 0;
        let h = tag === 'img' ? el.naturalHeight : tag === 'video' ? el.videoHeight : tag === 'canvas' ? el.height : 0;
        if (!w || !h) { w = inner.w; h = inner.h; }
        const natural = { w: Math.max(1, Math.round(w)), h: Math.max(1, Math.round(h)) };
        let drawnW = inner.w, drawnH = inner.h;
        if (tag !== 'svg' && inner.w > 0 && inner.h > 0) {
          const fit = style.objectFit, contain = Math.min(inner.w / natural.w, inner.h / natural.h);
          const scale = fit === 'contain' ? contain : fit === 'cover' ? Math.max(inner.w / natural.w, inner.h / natural.h)
                      : fit === 'none' ? 1 : fit === 'scale-down' ? Math.min(1, contain) : null;
          if (scale !== null) { drawnW = natural.w * scale; drawnH = natural.h * scale; }
        }
        const [ox, oy] = (style.objectPosition || '50% 50%').split(' ');
        const offset = (value, free) => value && value.endsWith('%') ? free * parseFloat(value) / 100 : px(value);
        const drawn = { x: inner.x + offset(ox, inner.w - drawnW), y: inner.y + offset(oy, inner.h - drawnH), w: drawnW, h: drawnH };
        return { natural, drawn, shown: intersect(drawn, inner) };
      }
      // A viewport rect on the picture as the picture's own pixels, and back (scaled to its current size).
      function toPixels(rect, box) {
        const sx = box.natural.w / box.drawn.w, sy = box.natural.h / box.drawn.h;
        const clamp = (value, max) => Math.min(max, Math.max(0, Math.round(value)));
        const x = clamp((rect.x - box.drawn.x) * sx, box.natural.w), y = clamp((rect.y - box.drawn.y) * sy, box.natural.h);
        const right = clamp((rect.x + rect.w - box.drawn.x) * sx, box.natural.w), bottom = clamp((rect.y + rect.h - box.drawn.y) * sy, box.natural.h);
        return { x, y, w: right - x, h: bottom - y, imageW: box.natural.w, imageH: box.natural.h };
      }
      function fromPixels(region, box) {
        const sx = box.drawn.w / region.imageW, sy = box.drawn.h / region.imageH;
        return { x: box.drawn.x + region.x * sx, y: box.drawn.y + region.y * sy, w: region.w * sx, h: region.h * sy };
      }
      const wholePicture = (box) => ({ x: 0, y: 0, w: box.natural.w, h: box.natural.h, imageW: box.natural.w, imageH: box.natural.h });
      // Where a region of a picture is on screen, cut to what the picture shows.
      function regionRect(el, region) {
        const box = pictureBox(el);
        return intersect(fromPixels(region, box), box.shown);
      }
      const pageOf = (r) => ({ x: r.x + scrollX, y: r.y + scrollY, w: r.w, h: r.h });

      // MARK: Overlay: boxes for element notes, the pick-mode hover and the chosen picture, drawn above everything,
      // taking no events.
      const boxes = new Map();
      let hover = null;
      function ensureOverlay() {
        if (overlay && overlay.isConnected) return overlay;
        overlay = document.createElement(OVERLAY);
        overlay.setAttribute('style', 'all:initial;position:absolute;left:0;top:0;width:0;height:0;z-index:2147483647;pointer-events:none;');
        root().appendChild(overlay);
        return overlay;
      }
      // The overlay is idle once nothing is drawn in it: it goes, so the page is left exactly as it was.
      function retireOverlayIfIdle() {
        if (overlay && overlay.isConnected && !picking && !boxes.size && !chosen) { retiredOverlay = overlay; overlay.remove(); overlay = null; }
      }
      function placeRect(box, r) {
        box.style.left = (r.x + scrollX) + 'px';
        box.style.top = (r.y + scrollY) + 'px';
        box.style.width = r.w + 'px';
        box.style.height = r.h + 'px';
      }
      // Where a note's box goes (viewport): its element, or on a picture the part of it the note is about.
      function noteRect(el, region) {
        if (region) return regionRect(el, region);
        const r = el.getBoundingClientRect();
        return { x: r.left, y: r.top, w: r.width, h: r.height };
      }
      function place(box, el) { placeRect(box, noteRect(el, null)); }
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
          for (const [, entry] of boxes) {
            if (!entry.element) continue;
            if (entry.element.isConnected) placeRect(entry.box, noteRect(entry.element, entry.region)); else entry.box.style.display = 'none';
          }
          if (hover) place(hover.box, hover.element);
          if (chosen) {
            drawChosen();
            // The Add Note button beside a chosen picture follows it as the page scrolls.
            if (chosen && chosen.selected) post({ pictureRect: regionRect(chosen.element, chosen.region) });
          }
          // The app draws paths to element notes: it needs their boxes after every scroll and resize.
          if (boxes.size) post({ elementRects: elementRects() });
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
      // Text offsets cost a walk of the page each, so they are asked for only on served files, and only for the
      // first few text matches of a common text.
      function resolveElements(list, offsets) {
        return list.map((item) => {
          const { bySelector, byText } = findCandidates(item);
          let budget = 20;
          const found = (el) => ({ selector: selectorFor(el), tag: el.tagName.toLowerCase(), text: collapse(el.textContent || '').slice(0, 500),
                                   html: (el.outerHTML || '').slice(0, 2048), textOffset: offsets && budget-- > 0 ? textOffsetOf(el) : null,
                                   rect: (() => { const b = el.getBoundingClientRect(); return { x: b.left + scrollX, y: b.top + scrollY, w: b.width, h: b.height }; })(),
                                   natural: pictureOf(el) === el ? pictureBox(el).natural : null });
          return { id: item.id, bySelector: bySelector ? found(bySelector) : null, byText: byText.map(found) };
        });
      }
      // An orphaned note is drawn dashed where its element last was; the others at their element. The overlay is
      // made only when there is something to draw, so a page without element notes is left exactly as it is.
      function highlightElements(list) {
        for (const [, entry] of boxes) entry.box.remove();
        boxes.clear();
        const rects = {};
        if (!list.length) { retireOverlayIfIdle(); return rects; }
        ensureOverlay();
        for (const item of list) {
          let el = null;
          if (item.state !== 'orphaned') { try { el = document.querySelector(item.selector); } catch (e) {} }
          if (el && inOverlay(el)) el = null;
          if (!el && !(item.state === 'orphaned' && item.rect)) continue;
          const box = makeBox(item.color, item.needsReview ? '?' : null, item.state === 'orphaned');
          box.style.opacity = item.state === 'resolved' ? '0.3' : item.state === 'sent' ? '0.55' : '1';
          box.style.background = item.fill;
          overlay.appendChild(box);
          // A note on part of a picture is drawn over that part, scaled to the picture's size now; an orphan over
          // that part of where the picture last was.
          const region = item.region && (!el || pictureOf(el) === el) ? item.region : null;
          let last = el ? null : item.rect;
          if (last && region) {
            const sx = last.w / region.imageW, sy = last.h / region.imageH;
            last = { x: last.x + region.x * sx, y: last.y + region.y * sy, w: region.w * sx, h: region.h * sy };
          }
          if (el) {
            placeRect(box, noteRect(el, region));
          } else {
            box.style.left = last.x + 'px'; box.style.top = last.y + 'px';
            box.style.width = last.w + 'px'; box.style.height = last.h + 'px';
          }
          boxes.set(item.id, { box, element: el, region, rect: last });
          rects[item.id] = el ? noteRect(el, region) : { x: last.x - scrollX, y: last.y - scrollY, w: last.w, h: last.h };
        }
        return rects;
      }
      function elementRects() {
        const rects = {};
        for (const [id, entry] of boxes) {
          if (entry.element) rects[id] = noteRect(entry.element, entry.region);
          else if (entry.rect) rects[id] = { x: entry.rect.x - scrollX, y: entry.rect.y - scrollY, w: entry.rect.w, h: entry.rect.h };
        }
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

      // MARK: The chosen picture: all of it after a click, a region after a drag, drawn like a crop tool (the rest of
      // the picture dimmed, a white edge, corner handles, a size pill), as RegionStyle draws it in the other viewers.
      let chosen = null;
      let chosenParts = null;
      function drawChosen() {
        if (!chosen) return;
        if (!chosen.element.isConnected) { clearChosen(true); return; }
        const box = pictureBox(chosen.element);
        const cut = intersect(fromPixels(chosen.region, box), box.shown);
        ensureOverlay();
        ensureSheet();
        if (!chosenParts || !chosenParts.frame.isConnected) {
          const part = (style) => { const div = document.createElement('div'); div.setAttribute('style', 'all:initial;position:absolute;pointer-events:none;' + style); return div; };
          const frame = part('overflow:hidden;');
          const edge = part('box-sizing:border-box;border:1.5px solid #fff;box-shadow:0 0 0 1.5px rgba(0,0,0,0.35),0 0 0 100000px rgba(0,0,0,0.42);');
          const handles = ['left:0;top:0;border-left-width:4px;border-top-width:4px;', 'right:0;top:0;border-right-width:4px;border-top-width:4px;',
                           'left:0;bottom:0;border-left-width:4px;border-bottom-width:4px;', 'right:0;bottom:0;border-right-width:4px;border-bottom-width:4px;']
            .map((corner) => part('box-sizing:border-box;border:0 solid #fff;filter:drop-shadow(0 0 1px rgba(0,0,0,0.6));' + corner));
          for (const handle of handles) edge.appendChild(handle);
          frame.appendChild(edge);
          const pill = part('');
          overlay.appendChild(frame);
          overlay.appendChild(pill);
          chosenParts = { frame, edge, handles, pill };
        }
        const { frame, edge, handles, pill } = chosenParts;
        placeRect(frame, box.shown);
        edge.style.left = (cut.x - box.shown.x) + 'px'; edge.style.top = (cut.y - box.shown.y) + 'px';
        edge.style.width = cut.w + 'px'; edge.style.height = cut.h + 'px';
        const arm = Math.min(14, cut.w / 2, cut.h / 2) + 'px';
        for (const handle of handles) { handle.style.width = arm; handle.style.height = arm; }
        pill.style.left = (cut.x + cut.w / 2 + scrollX) + 'px';
        pill.style.top = (cut.y + cut.h + 8 + scrollY) + 'px';
        pill.setAttribute('data-size', chosen.region.w + ' × ' + chosen.region.h);
      }
      // Puts the chosen picture away; `report` tells the app (a click elsewhere, a text selection), which the app's
      // own clearing doesn't need.
      function clearChosen(report) {
        const was = chosen;
        chosen = null;
        if (chosenParts) { chosenParts.frame.remove(); chosenParts.pill.remove(); chosenParts = null; }
        retireOverlayIfIdle();
        if (report && was && was.selected) post({ pictureCleared: true });
        return !!was;
      }
      // A picture chosen outside note mode waits for Add Note, as a text selection does; in note mode it is the pick.
      function choose(element, region) {
        const rect = regionRect(element, region);
        const picked = { pick: describe(element), region: Object.assign({}, region, { rect, page: pageOf(rect) }) };
        if (picking) {
          clearChosen(false);
          post(picked);
          return;
        }
        chosen = { element, region, selected: true };
        const selection = getSelection();
        if (selection && !selection.isCollapsed) selection.removeAllRanges();
        drawChosen();
        picked.select = true;
        post(picked);
      }

      // MARK: The picture gesture: a press on a picture, then a drag past 3 points for a region or a release for all
      // of it, as in rendered Markdown. A press on text, or on nothing, is left to the page.
      let gesture = null;
      let swallowClick = false;
      function pressAt(x, y, picture) {
        if (!picture) { if (chosen) clearChosen(true); return false; }
        gesture = { picture, x, y, dragged: false, again: !picking && !!chosen && chosen.element === picture };
        return true;
      }
      function dragTo(x, y) {
        if (!gesture) return;
        if (!gesture.dragged && Math.hypot(x - gesture.x, y - gesture.y) <= 3) return;
        gesture.dragged = true;
        const box = pictureBox(gesture.picture);
        const rect = intersect({ x: Math.min(x, gesture.x), y: Math.min(y, gesture.y), w: Math.abs(x - gesture.x), h: Math.abs(y - gesture.y) }, box.shown);
        chosen = { element: gesture.picture, region: toPixels(rect, box), selected: false };
        drawChosen();
      }
      function release() {
        const done = gesture;
        gesture = null;
        if (!done) return;
        const box = pictureBox(done.picture);
        if (done.dragged) {
          // A drag too thin to mean anything takes the whole picture.
          const region = chosen && chosen.region.w >= 2 && chosen.region.h >= 2 ? chosen.region : wholePicture(box);
          choose(done.picture, region);
          swallowClick = true;
          return;
        }
        // A click on the picture already chosen goes on to the page: a linked picture follows its link.
        if (done.again) { clearChosen(true); return; }
        choose(done.picture, wholePicture(box));
        // The first click chooses; it doesn't follow the picture's link or open the page's own viewer.
        swallowClick = true;
      }
      const plainPress = (event) => event.isTrusted && event.button === 0 && !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey;
      document.addEventListener('mousedown', (event) => {
        swallowClick = false;
        if (picking || !plainPress(event)) return;
        // No native drag of the image and no text selection starting under it; the page still sees the press.
        if (pressAt(event.clientX, event.clientY, plainPictureAt(event.clientX, event.clientY))) event.preventDefault();
      }, { capture: true });
      window.addEventListener('mousemove', (event) => { if (gesture && event.isTrusted) { event.preventDefault(); dragTo(event.clientX, event.clientY); } }, { capture: true });
      window.addEventListener('mouseup', (event) => { if (gesture && event.isTrusted) release(); }, { capture: true });
      document.addEventListener('click', (event) => {
        if (!swallowClick || !event.isTrusted) return;
        swallowClick = false;
        event.preventDefault();
        event.stopPropagation();
      }, { capture: true });

      // MARK: Pick mode: any element, the picture under the pointer before its wrappers, ↑ and ↓ to step to the parent
      // or back down.
      let picking = false;
      function targetAt(event) {
        const picture = pictureAt(event.clientX, event.clientY);
        if (picture) return picture;
        const el = document.elementFromPoint(event.clientX, event.clientY);
        return el && !inOverlay(el) && el !== root() && el !== document.body ? el : null;
      }
      const short = (el) => el.tagName.toLowerCase() + (el.id ? '#' + el.id : el.classList && el.classList.length ? '.' + el.classList[0] : '');
      // `origin` is the element under the pointer; the hovered element is it or one it was stepped to.
      function showHover(el, origin) {
        clearHover();
        ensureOverlay();
        const parent = el.parentElement && el.parentElement !== root() && el.parentElement !== document.body ? el.parentElement : null;
        const box = makeBox('var(--gloss-accent, #0a84ff)', (parent ? short(parent) + ' › ' : '') + short(el), false);
        box.style.background = 'rgba(10,132,255,0.10)';
        overlay.appendChild(box);
        place(box, el);
        hover = { box, element: el, origin };
      }
      function onMove(event) {
        if (!event.isTrusted || gesture) return;
        const el = targetAt(event);
        if (!el) { clearHover(); return; }
        if (hover && hover.origin === el) return;
        showHover(el, el);
      }
      function stepHover(up) {
        if (!hover) return false;
        let next;
        if (up) {
          next = hover.element.parentElement;
        } else if (hover.element !== hover.origin && hover.element.contains(hover.origin)) {
          // Back down the way it came.
          next = hover.origin;
          while (next.parentElement !== hover.element) next = next.parentElement;
        } else {
          next = hover.element.firstElementChild;
          while (next && inOverlay(next)) next = next.nextElementSibling;
        }
        if (!next || next === root() || next === document.body) return false;
        showHover(next, hover.origin);
        return true;
      }
      function clearHover() { if (hover) { hover.box.remove(); hover = null; } }
      // One pick per left press, of the hovered element; the click and release that follow are only swallowed. A
      // picture waits for the release, so a drag across it picks a region.
      function pickPressed(el, x, y) {
        if (!el) return;
        if (pictureOf(el) === el) { pressAt(x, y, el); return; }
        post({ pick: describe(el) });
      }
      function onPress(event) {
        event.preventDefault();
        event.stopPropagation();
        // Only the user's own press picks: a page dispatching a synthetic mousedown can't choose the element.
        if (!event.isTrusted || event.button !== 0) return;
        pickPressed(hover ? hover.element : targetAt(event), event.clientX, event.clientY);
      }
      function swallow(event) { event.preventDefault(); event.stopPropagation(); }
      function onKey(event) {
        if (!event.isTrusted) return;
        if (event.key === 'Escape') { swallow(event); post({ pickCancel: true }); return; }
        if ((event.key === 'ArrowUp' || event.key === 'ArrowDown') && stepHover(event.key === 'ArrowUp')) swallow(event);
      }
      function setPickMode(on) {
        if (on === picking) return;
        picking = on;
        gesture = null;
        // A region half dragged is dropped; note mode and a chosen picture don't mix, so entering it puts that away.
        if (chosen && !chosen.selected) clearChosen(false);
        else if (on && chosen) clearChosen(true);
        const opts = { capture: true };
        if (on) {
          document.addEventListener('mousemove', onMove, opts);
          document.addEventListener('mousedown', onPress, opts);
          document.addEventListener('mouseup', swallow, opts);
          document.addEventListener('click', swallow, opts);
          document.addEventListener('keydown', onKey, opts);
          document.addEventListener('mouseleave', clearHover, opts);
        } else {
          document.removeEventListener('mousemove', onMove, opts);
          document.removeEventListener('mousedown', onPress, opts);
          document.removeEventListener('mouseup', swallow, opts);
          document.removeEventListener('click', swallow, opts);
          document.removeEventListener('keydown', onKey, opts);
          document.removeEventListener('mouseleave', clearHover, opts);
          clearHover();
          retireOverlayIfIdle();
        }
      }

      // MARK: Text highlights. A constructed stylesheet adds no text node, so page-text offsets stay those of the source.
      let sheet = null;
      // The overlay's labels and the size pill are pseudo-elements, so they add no text to the page.
      const labelCSS = OVERLAY + ' div[data-label]::after { content: attr(data-label); position: absolute; left: 0; top: -18px; font: 11px -apple-system, sans-serif; color: #fff; background: rgba(10,132,255,0.9); padding: 1px 5px; border-radius: 3px; white-space: nowrap; }\\n'
        + OVERLAY + ' div[data-size]::after { content: attr(data-size); display: block; transform: translateX(-50%); font: 600 11px -apple-system, sans-serif; font-variant-numeric: tabular-nums; color: #fff; background: rgba(0,0,0,0.72); padding: 2px 6px; border-radius: 9px; white-space: nowrap; }\\n';
      function ensureSheet() {
        if (!sheet) { sheet = new CSSStyleSheet(); sheet.replaceSync(labelCSS); }
        // A page that sets its own adoptedStyleSheets drops ours; put it back.
        if (!document.adoptedStyleSheets.includes(sheet)) document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
      }
      window.__cc = {
        // The pick a trusted press makes, by point, after stepping `steps` ('up', 'down') from the element there; it
        // returns the hover label. Lives on __cc, which only the app's content world sees: the page can't call it,
        // and its synthetic events are ignored by onPress.
        pickAt(x, y, steps) {
          const el = targetAt({ clientX: x, clientY: y });
          if (!el) return null;
          showHover(el, el);
          for (const step of steps || []) stepHover(step === 'up');
          const label = hover.box.getAttribute('data-label');
          const picked = hover.element;
          if (!picking) clearHover();
          if (pictureOf(picked) === picked) choose(picked, wholePicture(pictureBox(picked))); else post({ pick: describe(picked) });
          return label;
        },
        // The picture gesture a trusted press, drag and release make, by points (the same point twice is a click).
        dragAt(x0, y0, x1, y1) {
          if (!pressAt(x0, y0, picking ? pictureOf(targetAt({ clientX: x0, clientY: y0 })) : plainPictureAt(x0, y0))) return false;
          dragTo(x1, y1);
          release();
          return true;
        },
        // Puts the chosen picture away (the app cleared its selection, or is about to snapshot the page); whether
        // there was one.
        clearPicture() { return clearChosen(false); },
        // Hides everything the overlay draws (note boxes, the hover) while the page is photographed for a crop.
        setOverlayHidden(hidden) {
          if (!overlay || !overlay.isConnected) return false;
          overlay.style.visibility = hidden ? 'hidden' : 'visible';
          return true;
        },
        highlight(list, css) {
          ensureSheet();
          sheet.replaceSync(labelCSS + css);
          if (!window.CSS || !CSS.highlights) return;
          // Only our own highlights: the page may have its own.
          for (const name of [...CSS.highlights.keys()]) { if (name.startsWith('gloss-note-')) CSS.highlights.delete(name); }
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

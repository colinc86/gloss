import Foundation

/// The script the app injects into every page, in the `.defaultClient` world where page scripts cannot see it.
/// It reports the selection, paints note highlights (CSS custom highlights), scrolls to notes, and says when the
/// page's text changes so offsets can be re-aligned.
enum WebBridge {
    static let handlerName = "gloss"

    static let script = """
    (() => {
      const post = (message) => window.webkit.messageHandlers.gloss.postMessage(message);
      const root = () => document.documentElement;
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
      // Page scripts may rewrite the text; the app re-aligns its map once they settle.
      let changeTimer = null;
      new MutationObserver(() => { clearTimeout(changeTimer); changeTimer = setTimeout(() => post({ changed: true }), 200); })
        .observe(root(), { childList: true, characterData: true, subtree: true });
      window.addEventListener('scroll', () => { if (!getSelection().isCollapsed) { clearTimeout(timer); timer = setTimeout(report, 60); } }, { passive: true });
      // A constructed stylesheet adds no text node, so page-text offsets stay those of the source.
      let sheet = null;
      window.__cc = {
        highlight(list, css) {
          if (!sheet) { sheet = new CSSStyleSheet(); document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet]; }
          sheet.replaceSync(css);
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
      };
    })();
    """
}

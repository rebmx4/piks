import Foundation

// Scope legacy editor URLs at their DOM/network boundary. Project documents
// keep the original stable URLs, including on older /ryn/ web versions.
enum MediaDocumentScript {
    static let marker = "// APIKS document media scope\n"
    static func source(token: String) -> String {
        precondition(token.count == 32 && token.allSatisfy({ $0.isASCII && $0.isHexDigit }))
        return marker + template.replacingOccurrences(of: "__APIKS_DOCUMENT_TOKEN__", with: token)
    }
    private static let template = #"""
    (() => {
      'use strict';
      if (window !== window.top) return;
      let token = '__APIKS_DOCUMENT_TOKEN__';
      const key = '__apiks_doc';
      function rewrite(raw, scoped) {
        if (typeof raw !== 'string' || !raw.startsWith('ryndi-media:')) return raw;
        try {
          const url = new URL(raw); url.searchParams.delete(key);
          if (scoped) url.searchParams.set(key, token);
          return url.href;
        } catch { return raw; }
      }
      function property(type, name, writable) {
        const d = Object.getOwnPropertyDescriptor(type.prototype, name);
        if (!d?.get || !d.configurable) return;
        const next = { ...d, get() { return rewrite(d.get.call(this), false); } };
        if (writable && d.set) next.set = function(value) { d.set.call(this, rewrite(String(value), true)); };
        Object.defineProperty(type.prototype, name, next);
      }
      for (const type of [HTMLMediaElement, HTMLImageElement, HTMLSourceElement, HTMLTrackElement]) property(type, 'src', true);
      property(HTMLVideoElement, 'poster', true);
      for (const type of [HTMLMediaElement, HTMLImageElement]) property(type, 'currentSrc', false);
      const set = Element.prototype.setAttribute, get = Element.prototype.getAttribute;
      const isSource = name => /^(src|poster)$/i.test(name);
      const isMedia = element => /^(IMG|VIDEO|AUDIO|SOURCE|TRACK)$/.test(element.tagName);
      Element.prototype.setAttribute = function(name, value) {
        return set.call(this, name, isMedia(this) && isSource(name) ? rewrite(String(value), true) : value);
      };
      Element.prototype.getAttribute = function(name) {
        const value = get.call(this, name); return isSource(name) ? rewrite(value, false) : value;
      };
      const fetch = window.fetch;
      window.fetch = function(input, init) {
        if (input instanceof Request && input.url.startsWith('ryndi-media:')) input = new Request(rewrite(input.url, true), input);
        else if (typeof input === 'string' || input instanceof URL) input = rewrite(String(input), true);
        return fetch.call(this, input, init);
      };
      const open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url, ...rest) { return open.call(this, method, rewrite(String(url), true), ...rest); };
      const scopeElement = element => {
        if (!(element instanceof Element) || !isMedia(element)) return;
        for (const name of ['src', 'poster']) {
          const value = get.call(element, name), next = rewrite(value, true);
          if (next !== value) set.call(element, name, next);
        }
      };
      new MutationObserver(records => {
        for (const record of records) {
          if (record.type === 'attributes') scopeElement(record.target);
          else for (const node of record.addedNodes) {
            scopeElement(node);
            if (node.querySelectorAll) node.querySelectorAll('[src],[poster]').forEach(scopeElement);
          }
        }
      }).observe(document, { subtree: true, childList: true, attributes: true, attributeFilter: ['src', 'poster'] });
      const bind = () => window.webkit.messageHandlers.ryndi.postMessage({cmd: 'document-ready', token});
      Object.defineProperty(window, '__apiksMediaDocument', { value(next) {
        if (!/^[a-f0-9]{32}$/.test(next)) return;
        const changed = next !== token; token = next;
        bind();
        if (changed) document.querySelectorAll('[src],[poster]').forEach(scopeElement);
      } });
      bind();
    })();
    """#
}

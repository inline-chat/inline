import Foundation

/// Bundled runtime served from `/_rt/` on every widget origin. It never needs
/// the network, so a widget that uses only these assets renders offline.
public enum WidgetRuntime {
  public static let cssPath = "/_rt/inline.css"
  public static let scriptPath = "/_rt/inline.js"
  public static let messageHandlerName = "inlineWidget"

  /// Classless base plus a small utility set. Colors come from the theme
  /// variables in `#inline-theme`, which the host rewrites on theme changes.
  public static let css = """
  html{box-sizing:border-box;padding:4px;margin:0;background:transparent;color:var(--foreground);\
  font-family:var(--font-sans);font-size:14px;line-height:1.5;-webkit-font-smoothing:antialiased;\
  -webkit-text-size-adjust:100%;overflow:hidden}
  *,*::before,*::after{box-sizing:inherit}
  body{margin:0}
  h1,h2,h3,p{margin:0}
  h1{font-size:20px;font-weight:500}h2{font-size:17px;font-weight:500}h3{font-size:15px;font-weight:500}
  code,kbd,pre,samp{font-family:var(--font-mono);font-size:12.5px}
  a{color:var(--primary)}
  :where(:focus-visible){outline:2px solid var(--ring);outline-offset:-2px}
  .muted{color:var(--muted-foreground)}.small{font-size:12px}.tabular-nums{font-variant-numeric:tabular-nums}
  .sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);border:0}
  .card{background:var(--card);border:0.5px solid var(--border);border-radius:var(--radius);padding:12px 14px}
  .grid{display:grid;gap:10px;grid-template-columns:repeat(auto-fit,minmax(150px,1fr))}
  .row{display:flex;flex-wrap:wrap;align-items:center;gap:8px}
  .badge{display:inline-block;font-size:12px;padding:2px 8px;border-radius:999px;background:var(--accent);color:var(--accent-foreground)}
  .btn,button{font:inherit;font-size:13px;color:var(--foreground);background:transparent;border:0.5px solid var(--border-strong);\
  border-radius:var(--radius);padding:5px 12px;cursor:default}
  .btn:active,button:active{background:var(--muted)}
  .btn-primary{background:var(--primary);color:var(--primary-foreground);border-color:transparent}
  .btn-ghost{border-color:transparent}
  input,select,textarea{font:inherit;font-size:13px;color:var(--foreground);background:var(--card);\
  border:0.5px solid var(--border-strong);border-radius:var(--radius);padding:4px 8px}
  table.table{width:100%;border-collapse:collapse;font-size:13px}
  .table th,.table td{text-align:left;padding:6px 8px;border-bottom:0.5px solid var(--border)}
  .table th{color:var(--muted-foreground);font-weight:500}
  img{max-width:100%}
  """

  /// Bridge, autosize, link and image interception, error capture.
  /// Native side validates origin and user gesture; this shim is convenience.
  public static let script = #"""
  (function(){
    if (window.inline) return;
    var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.inlineWidget;
    var init = window.__inlineInit || {};
    var seq = 0, pending = {}, state = init.state === undefined ? null : init.state;
    var context = init.context || {};
    function post(method, params, id){
      if (!handler) return;
      var msg = {jsonrpc:"2.0", method:method, params:params || {}};
      if (id !== undefined) msg.id = id;
      handler.postMessage(msg);
    }
    function request(method, params){
      return new Promise(function(resolve, reject){
        var id = ++seq; pending[id] = {resolve:resolve, reject:reject}; post(method, params, id);
      });
    }
    function applyTheme(vars, appearance){
      var el = document.getElementById("inline-theme"); if (!el || !vars) return;
      var css = ":root{color-scheme:" + (appearance === "dark" ? "dark" : "light") + ";";
      for (var k in vars) if (/^--[a-z0-9-]+$/.test(k)) css += k + ":" + String(vars[k]).replace(/[;{}<>]/g, "") + ";";
      el.textContent = css + "}";
    }
    window.__inlineWidgetReceive = function(msg){
      if (!msg) return;
      if (msg.id !== undefined && pending[msg.id]) {
        var p = pending[msg.id]; delete pending[msg.id];
        if (msg.error) p.reject(new Error(msg.error.message || "Rejected")); else p.resolve(msg.result);
        return;
      }
      if (msg.method === "ui/notifications/host-context-changed" && msg.params) {
        if (msg.params.styles) applyTheme(msg.params.styles.variables, msg.params.theme);
        if (msg.params.context) context = msg.params.context;
        window.dispatchEvent(new CustomEvent("inline:context", {detail: context}));
      }
    };
    var api = {
      copy: function(text){ return request("inline/copy", {text: String(text)}); },
      sendPrompt: function(text){ return request("ui/message", {text: String(text)}); },
      action: function(name, payload){ return request("inline/action", {name: String(name), payload: payload === undefined ? null : payload}); },
      openLink: function(url){ return request("ui/open-link", {url: String(url)}); },
      openImage: function(src, name){ return request("inline/open-image", {src: String(src), name: name ? String(name) : ""}); },
      setState: function(value){ state = value; post("inline/state", {state: value}); },
      get state(){ return state; },
      get context(){ return context; }
    };
    Object.defineProperty(window, "inline", {value: Object.freeze(api), writable: false, configurable: false});
    // Names agents already use with Claude and other hosts.
    window.sendPrompt = api.sendPrompt;
    window.openLink = api.openLink;

    document.addEventListener("click", function(e){
      if (!e.isTrusted) return;
      var path = e.composedPath();
      for (var i = 0; i < path.length; i++) {
        var t = path[i];
        if (t && t.tagName === "A" && t.getAttribute("href")) {
          var u; try { u = new URL(t.getAttribute("href"), document.baseURI); } catch (x) { return; }
          if (u.protocol === "https:" || u.protocol === "http:") { e.preventDefault(); api.openLink(u.href).catch(function(){}); }
          else if (u.href.split("#")[0] !== location.href.split("#")[0]) e.preventDefault();
          return;
        }
        if (t && t.tagName === "BUTTON") return;
      }
      var img = path[0];
      if (img && img.tagName === "IMG" && !e.defaultPrevented) api.openImage(img.currentSrc || img.src, img.alt || "").catch(function(){});
    }, true);

    var lastHeight = -1, raf = 0;
    function measure(){
      raf = 0;
      var h = Math.ceil(document.documentElement.getBoundingClientRect().height);
      if (h !== lastHeight) { lastHeight = h; post("ui/notifications/size-changed", {height: h}); }
    }
    function schedule(){ if (!raf) raf = requestAnimationFrame(measure); }
    if (window.ResizeObserver) {
      var ro = new ResizeObserver(schedule);
      ro.observe(document.documentElement);
      document.addEventListener("DOMContentLoaded", function(){ if (document.body) ro.observe(document.body); });
    }
    var errors = 0;
    window.addEventListener("error", function(e){
      if (errors++ >= 3) return;
      post("inline/notifications/error", {message: String(e.message || "Error").slice(0, 500), line: e.lineno || 0});
    });
    window.addEventListener("unhandledrejection", function(e){
      if (errors++ >= 3) return;
      post("inline/notifications/error", {message: String(e.reason && e.reason.message || e.reason || "Rejection").slice(0, 500)});
    });
    window.addEventListener("load", function(){
      measure();
      // Two frames after load: content has painted, so the host can swap out the snapshot.
      requestAnimationFrame(function(){ requestAnimationFrame(function(){ measure(); post("inline/notifications/rendered", {height: lastHeight}); }); });
    });
  })();
  """#
}

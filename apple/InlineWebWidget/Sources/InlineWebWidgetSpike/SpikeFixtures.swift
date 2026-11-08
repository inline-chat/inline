import AppKit
import InlineWebWidget

/// Widget kinds the spike exercises: static SVG, canvas, CDN chart, WebGL,
/// stateful picker, album with bot media, tall content, and a security probe.
enum SpikeFixture: String, CaseIterable {
  case diagram, canvas, chartjs, webgl, picker, album, tall, security

  var title: String {
    switch self {
    case .diagram: "Request flow"
    case .canvas: "Latency by region"
    case .chartjs: "Weekly signups"
    case .webgl: "WebGL surface"
    case .picker: "Onboarding variants"
    case .album: "Screenshots"
    case .tall: "Long checklist"
    case .security: "Security probe"
    }
  }

  var heightHint: Int? {
    switch self {
    case .diagram: 200
    case .canvas: 250
    case .chartjs: 280
    case .webgl: 200
    case .picker: nil // exercises the default and a measured correction
    case .album: 240
    case .tall: 1400
    case .security: 80
    }
  }

  func content(key: String) -> WidgetContent {
    WidgetContent(key: key, title: title, html: html, heightHint: heightHint, media: self == .album ? Self.albumMedia : [])
  }

  var html: String {
    switch self {
    case .diagram:
      return """
      <h2 class="sr-only">Request flow from client to database</h2>
      <svg viewBox="0 0 600 180" width="100%" role="img" aria-label="Client, API, worker, database">
        <g font-family="var(--font-sans)" font-size="13">
          <rect x="10" y="60" width="120" height="56" rx="8" fill="var(--accent)" stroke="var(--primary)"/>
          <text x="70" y="93" text-anchor="middle" fill="var(--foreground)">Client</text>
          <rect x="170" y="60" width="120" height="56" rx="8" fill="var(--muted)" stroke="var(--border)"/>
          <text x="230" y="93" text-anchor="middle" fill="var(--foreground)">API</text>
          <rect x="330" y="10" width="120" height="56" rx="8" fill="var(--muted)" stroke="var(--border)"/>
          <text x="390" y="43" text-anchor="middle" fill="var(--foreground)">Worker</text>
          <rect x="330" y="110" width="120" height="56" rx="8" fill="var(--muted)" stroke="var(--border)"/>
          <text x="390" y="143" text-anchor="middle" fill="var(--foreground)">Postgres</text>
          <path d="M130 88H170M290 80L330 40M290 96L330 136" stroke="var(--muted-foreground)" fill="none"/>
        </g>
      </svg>
      """
    case .canvas:
      // A full document, to exercise head injection.
      return """
      <!doctype html><html><head><title>Latency</title><style>.wrap{position:relative;height:220px}</style></head>
      <body><div class="wrap"><canvas id="c" role="img" aria-label="p95 latency by region"></canvas></div>
      <script>
        const c = document.getElementById("c"), wrap = c.parentElement;
        function draw(){
          const dpr = devicePixelRatio, w = wrap.clientWidth, h = wrap.clientHeight;
          c.width = w * dpr; c.height = h * dpr; c.style.width = w + "px"; c.style.height = h + "px";
          const g = c.getContext("2d"); g.scale(dpr, dpr);
          const css = getComputedStyle(document.documentElement);
          const data = [["us-east", 120], ["us-west", 180], ["eu", 140], ["ap", 260], ["sa", 210]];
          const max = 300, bw = (w - 40) / data.length;
          g.font = "12px -apple-system"; g.fillStyle = css.getPropertyValue("--muted-foreground");
          data.forEach(([label, v], i) => {
            const bh = (h - 40) * v / max, x = 20 + i * bw + 8;
            g.fillStyle = css.getPropertyValue(v > 200 ? "--chart-2" : "--chart-1");
            g.fillRect(x, h - 24 - bh, bw - 16, bh);
            g.fillStyle = css.getPropertyValue("--muted-foreground");
            g.fillText(label, x, h - 8);
          });
        }
        draw(); addEventListener("resize", draw); addEventListener("inline:context", draw);
      </script></body></html>
      """
    case .chartjs:
      return """
      <div style="position:relative;height:260px"><canvas id="signups" role="img" aria-label="Weekly signups"></canvas></div>
      <script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.js"></script>
      <script>
        const css = getComputedStyle(document.documentElement);
        new Chart(document.getElementById("signups"), {
          type: "line",
          data: { labels: ["W1","W2","W3","W4","W5","W6","W7","W8"],
            datasets: [{ label: "Signups", data: [12,19,15,27,31,29,42,48], borderColor: css.getPropertyValue("--chart-1"), tension: 0.3 }] },
          options: { responsive: true, maintainAspectRatio: false, animation: false, plugins: { legend: { display: false } } }
        });
      </script>
      """
    case .webgl:
      return """
      <canvas id="gl" style="width:100%;height:180px;display:block;border-radius:8px" role="img" aria-label="Gradient"></canvas>
      <script>
        const cv = document.getElementById("gl"); cv.width = cv.clientWidth * devicePixelRatio; cv.height = 180 * devicePixelRatio;
        const gl = cv.getContext("webgl");
        if (gl) {
          const vs = gl.createShader(gl.VERTEX_SHADER);
          gl.shaderSource(vs, "attribute vec2 p;varying vec2 v;void main(){v=p*0.5+0.5;gl_Position=vec4(p,0,1);}"); gl.compileShader(vs);
          const fs = gl.createShader(gl.FRAGMENT_SHADER);
          gl.shaderSource(fs, "precision mediump float;varying vec2 v;void main(){gl_FragColor=vec4(v.x,0.4,v.y,1);}"); gl.compileShader(fs);
          const pr = gl.createProgram(); gl.attachShader(pr, vs); gl.attachShader(pr, fs); gl.linkProgram(pr); gl.useProgram(pr);
          const b = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, b);
          gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1,1,-1,-1,1,1,1]), gl.STATIC_DRAW);
          const loc = gl.getAttribLocation(pr, "p"); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
          gl.viewport(0, 0, cv.width, cv.height); gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
        }
      </script>
      """
    case .picker:
      return """
      <div id="picker">
        <div class="grid" role="radiogroup" aria-label="Variant">
          <label class="card"><input type="radio" name="v" value="A"> <b>A</b> <span class="muted small">Single step</span></label>
          <label class="card"><input type="radio" name="v" value="B"> <b>B</b> <span class="muted small">Guided tour</span></label>
          <label class="card"><input type="radio" name="v" value="C"> <b>C</b> <span class="muted small">Checklist</span></label>
        </div>
        <div class="row" style="margin-top:12px">
          <select id="tone"><option>Friendly</option><option>Neutral</option><option>Formal</option></select>
          <button class="btn-primary" id="pick">Pick</button>
          <button id="refine">Refine ↗</button>
          <button id="copy">Copy spec</button>
          <span id="status" class="muted small" aria-live="polite"></span>
        </div>
      </div>
      <script>
        const root = document.getElementById("picker"), status = document.getElementById("status");
        const s = inline.state || {};
        if (s.v) root.querySelector(`input[value="${s.v}"]`).checked = true;
        if (s.tone) document.getElementById("tone").value = s.tone;
        function save(){ const v = root.querySelector("input:checked"); inline.setState({ v: v && v.value, tone: document.getElementById("tone").value }); }
        root.addEventListener("change", save);
        const run = (p, ok) => p.then(() => status.textContent = ok, e => status.textContent = e.message);
        document.getElementById("pick").onclick = () => run(inline.action("pick", inline.state), "Sent");
        document.getElementById("refine").onclick = () => run(inline.sendPrompt("Refine variant " + ((inline.state || {}).v || "B")), "In composer");
        document.getElementById("copy").onclick = () => run(inline.copy(JSON.stringify(inline.state)), "Copied");
      </script>
      """
    case .album:
      let tile = { (hue: Int) in
        "data:image/svg+xml;utf8," + "<svg xmlns='http://www.w3.org/2000/svg' width='240' height='160'><rect width='240' height='160' fill='hsl(\(hue),60%,70%)'/></svg>"
          .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
      }
      return """
      <div class="grid" style="grid-template-columns:repeat(3,minmax(0,1fr))">
        <img src="\(tile(210))" alt="Home" style="border-radius:8px;width:100%">
        <img src="\(tile(30))" alt="Settings" style="border-radius:8px;width:100%">
        <img src="\(tile(150))" alt="Profile" style="border-radius:8px;width:100%">
        <img src="media/0" alt="Bot upload 1" style="border-radius:8px;width:100%">
        <img src="media/1" alt="Bot upload 2" style="border-radius:8px;width:100%">
      </div>
      """
    case .tall:
      let items = (1...60).map { "<li style=\"padding:4px 0;border-bottom:0.5px solid var(--border)\">Task \($0) <span class=\"badge\">step</span></li>" }.joined()
      return "<ol style=\"margin:0;padding-left:20px\">\(items)</ol>"
    case .security:
      return "<p class=\"muted\">Security probe widget. The harness runs checks from the page context.</p>"
    }
  }

  static let albumMedia: [Data] = [NSColor.systemIndigo, NSColor.systemMint].map { color in
    let image = NSImage(size: NSSize(width: 240, height: 160))
    image.lockFocus()
    color.setFill()
    NSRect(x: 0, y: 0, width: 240, height: 160).fill()
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
  }
}

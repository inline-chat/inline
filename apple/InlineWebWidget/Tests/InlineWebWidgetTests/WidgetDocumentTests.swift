import Testing
@testable import InlineWebWidget

@Suite struct WidgetDocumentTests {
  let theme = WidgetTheme(appearance: .light, variables: ["--foreground": "#000"])

  @Test func wrapsFragment() {
    let html = WidgetDocument.build(content: WidgetContent(key: "m1-r1", title: "T", html: "<p>hi</p>"), theme: theme, state: nil, context: [:])
    #expect(html.hasPrefix("<!doctype html><html><head>"))
    #expect(html.contains("<body><p>hi</p></body>"))
    #expect(html.contains(WidgetRuntime.scriptPath))
  }

  @Test func injectsIntoFullDocumentHead() {
    let source = "<!doctype html><html><head><title>x</title></head><body>b</body></html>"
    let html = WidgetDocument.build(content: WidgetContent(key: "k", title: "T", html: source), theme: theme, state: nil, context: [:])
    #expect(html.contains("<head><meta charset=\"utf-8\">"))
    #expect(html.components(separatedBy: "<head").count == 2)
  }

  @Test func stateCannotCloseScript() {
    let html = WidgetDocument.build(content: WidgetContent(key: "k", title: "T", html: "x"), theme: theme, state: "\"</script><script>alert(1)</script>\"", context: [:])
    #expect(!html.contains("</script><script>alert(1)"))
  }

  @Test func validationRules() {
    #expect(WidgetDocument.validate("<div style=\"height:100vh\"></div>")?.contains("vh") == true)
    #expect(WidgetDocument.validate("<iframe src=x>") != nil)
    #expect(WidgetDocument.validate("<input type=password>") != nil)
    #expect(WidgetDocument.validate("<div style=\"height:240px\">ok</div>") == nil)
    #expect(WidgetDocument.validate("<img src=\"data:image/png;base64,AB1vhC\">") == nil)
    #expect(WidgetDocument.validate(String(repeating: "a", count: 300_000)) != nil)
  }

  @Test func cspBlocksNetworkAndFrames() {
    let csp = WidgetDocument.contentSecurityPolicy
    #expect(csp.contains("connect-src 'none'"))
    #expect(csp.contains("frame-src 'none'"))
    #expect(csp.contains("img-src 'self' data: blob:"))
  }

  @Test func perWidgetOriginsDiffer() {
    #expect(WidgetURL.documentURL(for: "m1-r1", mode: .perWidget).host != WidgetURL.documentURL(for: "m2-r1", mode: .perWidget).host)
  }
}

import { describe, expect, it } from "vitest"
import { isPhoneNumberCandidate, safeLink, type SafeLink } from "./links"

const rejected: readonly (readonly [string, unknown])[] = [
  ["javascript", "javascript:alert(1)"],
  ["javascript mixed case", "JaVaScRiPt:alert(1)"],
  ["javascript upper", "JAVASCRIPT:alert(1)"],
  ["javascript with slashes", "javascript://example.com/%0aalert(1)"],
  ["javascript leading space", "  javascript:alert(1)"],
  ["javascript tab in scheme", "java\tscript:alert(1)"],
  ["javascript newline in scheme", "java\nscript:alert(1)"],
  ["javascript CR in scheme", "java\rscript:alert(1)"],
  ["javascript NUL prefix", "\u0000javascript:alert(1)"],
  ["javascript leading control", "\u0001javascript:alert(1)"],
  ["javascript zero-width space", "java\u200bscript:alert(1)"],
  ["javascript soft hyphen", "java\u00adscript:alert(1)"],
  ["javascript BOM prefix", "\ufeffjavascript:alert(1)"],
  ["javascript NBSP prefix", "\u00a0javascript:alert(1)"],
  ["javascript entity-encoded", "javascript&#58;alert(1)"],
  ["javascript percent-encoded scheme", "%6Aavascript:alert(1)"],
  ["javascript fullwidth colon", "javascript\uff1aalert(1)"],
  ["javascript with bare-domain option", "javascript:alert(1)//example.com"],
  ["vbscript", "vbscript:msgbox(1)"],
  ["VBScript", "VBScript:msgbox(1)"],
  ["data html", "data:text/html,<script>alert(1)</script>"],
  ["data base64", "data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg=="],
  ["data image", "data:image/svg+xml,<svg onload=alert(1)>"],
  ["file", "file:///etc/passwd"],
  ["file host", "file://server/share"],
  ["blob", "blob:https://example.com/uuid"],
  ["about", "about:blank"],
  ["ftp", "ftp://example.com/file"],
  ["chrome", "chrome://settings"],
  ["filesystem", "filesystem:https://example.com/temporary/x"],
  ["intent", "intent://scan/#Intent;scheme=zxing;end"],
  ["ws", "wss://example.com/socket"],
  ["unknown scheme", "slack://open"],
  ["scheme-relative", "//evil.com"],
  ["scheme-relative with path", "//evil.com/c/1"],
  ["triple slash", "///evil.com"],
  ["backslash scheme-relative", "\\\\evil.com"],
  ["slash backslash", "/\\evil.com"],
  ["path-relative", "/c/123"],
  ["https without slashes", "https:evil.com"],
  ["https one slash", "https:/evil.com"],
  ["https backslashes", "https:\\\\evil.com"],
  ["https slash backslash", "https:/\\evil.com"],
  ["backslash in authority", "https://good.com\\@evil.com"],
  ["credentials", "https://user:pass@example.com/"],
  ["username only", "https://user@example.com/"],
  ["empty userinfo", "https://@example.com/"],
  ["userinfo spoof", "https://inline.chat@evil.com/c/1"],
  ["encoded at in userinfo", "https://inline.chat%40evil.com@evil.com/"],
  ["empty host", "https:///path"],
  ["host only spaces", "https:// /"],
  ["interior space", "https://exa mple.com/"],
  ["interior tab", "https://example.com/\tpath"],
  ["newline in path", "https://example.com/a\nb"],
  ["line separator", "https://example.com/\u2028"],
  ["bidi override", "https://example.com/\u202egnp.exe"],
  ["bidi isolate", "https://\u2066example.com"],
  ["zero-width joiner in host", "https://exa\u200dmple.com/"],
  ["DEL", "https://example.com/\u007f"],
  ["variation selector in host", "https://exa\ufe0fmple.com/"],
  ["combining grapheme joiner in scheme", "java\u034fscript:alert(1)"],
  ["Arabic letter mark", "https://example.com/\u061c"],
  ["C1 control", "https://example.com/\u0085"],
  ["empty", ""],
  ["only spaces", "   "],
  ["not a string: number", 42],
  ["not a string: null", null],
  ["not a string: object", { href: "https://example.com" }],
  ["too long", `https://example.com/${"a".repeat(9000)}`],
  ["mailto javascript", "mailto:javascript:alert(1)"],
  ["mailto no address", "mailto:"],
  ["mailto two addresses", "mailto:a@example.com,b@example.com"],
  ["mailto no domain dot", "mailto:a@localhost"],
  ["mailto newline header", "mailto:a@example.com%0ABcc:b@example.com"],
  ["tel letters", "tel:call-me"],
  ["tel too short", "tel:12345"],
  ["tel two pluses", "tel:+1+2345678901"],
  ["tel unbalanced", "tel:(555-123-4567"],
  ["deep link unknown host", "inline://settings/danger"],
  ["deep link credentials", "inline://user:pw@chat/1"],
  ["deep link without slashes", "inline:chat/1"],
  ["deep link control", "inline://chat/1\u0000"],
]

describe("safeLink rejects", () => {
  it.each(rejected)("%s", (_name, input) => {
    expect(safeLink(input)).toBeUndefined()
    expect(safeLink(input, { bareDomain: true })).toBeUndefined()
  })
})

const accepted: readonly (readonly [string, string, SafeLink["kind"], string])[] = [
  ["https", "https://example.com/a?b=1#c", "web", "https://example.com/a?b=1#c"],
  ["http", "http://example.com", "web", "http://example.com/"],
  ["upper-case scheme normalized", "HTTPS://Example.COM/Path", "web", "https://example.com/Path"],
  ["mixed-case scheme normalized", "HtTp://example.com", "web", "http://example.com/"],
  ["surrounding spaces trimmed", "  https://example.com  ", "web", "https://example.com/"],
  ["port", "https://example.com:8443/x", "web", "https://example.com:8443/x"],
  ["localhost", "http://localhost:3000/", "web", "http://localhost:3000/"],
  ["ipv6", "https://[::1]/", "web", "https://[::1]/"],
  ["IDN to punycode", "https://b\u00fccher.de/", "web", "https://xn--bcher-kva.de/"],
  ["percent-encoded path", "https://example.com/a%20b", "web", "https://example.com/a%20b"],
  ["unencoded query characters", "https://example.com/?q=a|b", "web", "https://example.com/?q=a|b"],
  ["non-ASCII path percent-encoded", "https://fa.wikipedia.org/wiki/\u0627\u06cc\u0631\u0627\u0646", "web", "https://fa.wikipedia.org/wiki/%D8%A7%DB%8C%D8%B1%D8%A7%D9%86"],
  ["mailto", "mailto:ada@example.com", "mail", "mailto:ada@example.com"],
  ["mailto upper scheme", "MAILTO:ada@example.com", "mail", "mailto:ada@example.com"],
  ["mailto query dropped", "mailto:ada@example.com?subject=hi&body=x", "mail", "mailto:ada@example.com"],
  ["mailto encoded at", "mailto:ada%40example.com", "mail", "mailto:ada@example.com"],
  ["tel", "tel:+1 555 123 4567".replace(/ /g, "-"), "phone", "tel:+15551234567"],
  ["tel parentheses", "tel:(555)123-4567", "phone", "tel:5551234567"],
  ["tel params dropped", "tel:+15551234567;ext=12", "phone", "tel:+15551234567"],
  ["deep link chat", "inline://chat/123", "app", "inline://chat/123"],
  ["deep link short scheme", "in://user/42", "app", "in://user/42"],
  ["deep link upper scheme", "INLINE://chat/1", "app", "inline://chat/1"],
  ["deep link message", "inline://chat/1/message/2", "app", "inline://chat/1/message/2"],
  ["deep link join", "inline://join/invite/iv1_x", "app", "inline://join/invite/iv1_x"],
  ["public chat", "https://inline.chat/c/123", "app", "https://inline.chat/c/123"],
  ["public space", "https://inline.chat/s/@team", "app", "https://inline.chat/s/@team"],
  ["public invite", "https://inline.chat/invite/iv1_abc", "app", "https://inline.chat/invite/iv1_abc"],
  ["app origin", "https://app.inline.chat/c/1/m/2", "app", "https://app.inline.chat/c/1/m/2"],
  ["public non-app page is web", "https://inline.chat/blog/post", "web", "https://inline.chat/blog/post"],
  ["http public is web", "http://inline.chat/c/1", "web", "http://inline.chat/c/1"],
  ["public on a port is web", "https://inline.chat:444/c/1", "web", "https://inline.chat:444/c/1"],
  ["lookalike host is web", "https://inline.chat.evil.com/c/1", "web", "https://inline.chat.evil.com/c/1"],
]

describe("safeLink accepts and normalizes", () => {
  it.each(accepted)("%s", (_name, input, kind, href) => {
    const link = safeLink(input)
    expect(link?.kind).toBe(kind)
    expect(link?.href).toBe(href)
  })

  it("returns parsed parts for app links", () => {
    expect(safeLink("inline://chat/12?message_id=5")).toEqual({
      kind: "app",
      form: "deepLink",
      href: "inline://chat/12?message_id=5",
      host: "chat",
      path: ["12"],
      query: [["message_id", "5"]],
    })
    expect(safeLink("https://inline.chat/c/9")).toMatchObject({ kind: "app", form: "public", host: "inline.chat", path: ["c", "9"] })
    expect(safeLink("https://app.inline.chat/space/3/members")).toMatchObject({
      kind: "app",
      form: "app",
      path: ["space", "3", "members"],
    })
  })

  it("takes extra app origins and schemes", () => {
    expect(safeLink("http://localhost:8001/c/1", { appOrigins: ["http://localhost:8001"] })).toMatchObject({
      kind: "app",
      form: "app",
    })
    expect(safeLink("inline-dev://chat/1")).toBeUndefined()
    expect(safeLink("inline-dev://chat/1", { appSchemes: ["inline-dev"] })).toMatchObject({ kind: "app", host: "chat" })
  })

  it("reports the web host for display", () => {
    expect(safeLink("https://Example.com:8080/x")).toMatchObject({ kind: "web", host: "example.com:8080" })
  })

  it("returns mail address and phone number as written", () => {
    expect(safeLink("mailto:ada@example.com")).toMatchObject({ address: "ada@example.com" })
    expect(safeLink("tel:(555)123-4567")).toMatchObject({ number: "(555)123-4567" })
  })
})

describe("bare domains", () => {
  const bare: readonly (readonly [string, string | undefined])[] = [
    ["example.com", "https://example.com/"],
    ["www.example.com/path?q=1#x", "https://www.example.com/path?q=1#x"],
    ["example.com:8080/x", "https://example.com:8080/x"],
    ["1.2.3.4/x", "https://1.2.3.4/x"],
    ["sub.b\u00fccher.de", "https://sub.xn--bcher-kva.de/"],
    ["example", undefined],
    ["example.c", undefined],
    ["-bad.com", undefined],
    ["user@example.com", undefined],
    ["user:pw@example.com", undefined],
    ["example.com:port", undefined],
    ["999.1.1.1/", undefined],
    ["./relative", undefined],
    ["..", undefined],
  ]
  it.each(bare)("%s", (input, href) => {
    expect(safeLink(input, { bareDomain: true })?.href).toBe(href)
  })

  it("only with the option", () => {
    expect(safeLink("example.com")).toBeUndefined()
  })

  it("recognizes bare app links", () => {
    expect(safeLink("inline.chat/c/5", { bareDomain: true })).toMatchObject({ kind: "app", form: "public" })
    expect(safeLink("app.inline.chat/c/5", { bareDomain: true })).toMatchObject({ kind: "app", form: "app" })
  })
})

describe("isPhoneNumberCandidate (Apple rule)", () => {
  it.each([
    ["+15551234567", true],
    ["5551234567", true],
    ["555-123-4567", true],
    ["(555)123-4567", true],
    ["+49301234", true],
    ["1234567", false],
    ["123456789", false],
    ["(12)34567", true],
    ["1234567890123456", false],
    ["12+34567890", false],
    ["++15551234567", false],
    [")555(1234567", false],
    ["555 123 4567", false],
    ["555.123.4567", false],
    ["", false],
  ] as const)("%s \u2192 %s", (input, expected) => {
    expect(isPhoneNumberCandidate(input)).toBe(expected)
  })
})

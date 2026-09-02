import CoreGraphics
import Foundation
import Testing
@testable import InlineMath

@Suite("Bounded native math rendering")
struct MathRendererTests {
  @Test("common formulas produce pixels with finite baseline metrics", arguments: [
    "x^2+y^2=z^2", #"\frac{a}{b}"#, #"\sqrt{x^2+1}"#,
    #"\sum_{n=1}^{\infty}\frac{1}{n^2}"#, #"\int_0^1 x\,dx"#,
    #"\begin{pmatrix}a&b\\c&d\end{pmatrix}"#, #"\overline{x}+\underline{y}"#,
    #"\color{#ff0000}{x}+\colorbox{#0000ff}{y}"#, #"\!x"#,
    #"x+\textcolor{#ff0000}{\frac{a}{b}}"#, #"x+\textcolor{#ff0000}{}"#,
    #"\overline{x}^{a^b}"#,
    #"{\overline{\left(x\right)}}^{{\begin{matrix}\pi&\pi\end{matrix}}^{\widehat{\alpha}}}"#,
  ])
  func formulas(_ tex: String) async throws {
    let image = try await MathRenderer.shared.render(request(tex)).get()
    #expect(image.width > 0 && image.height > 0)
    #expect(image.ascent >= 0 && image.descent >= 0)
    #expect(image.width.isFinite && image.height.isFinite)
    #expect(image.image.width <= 4096 && image.image.height <= 4096)
    #expect(image.height == CGFloat(image.image.height) / image.scale)
    let data = try #require(image.image.dataProvider?.data as Data?)
    #expect(stride(from: 3, to: data.count, by: 4).contains { data[$0] > 0 })
  }

  @Test("syntax failures and hostile depth fall back without rendering")
  func failures() async {
    for tex in [#"\unknown{x}"#, "{x", #"\left(x"#, "😀+x", "α+x", "x#y", "x\u{20d7}",
                #"&\sqrt\\{^_}+={(\sqrt-\\\\_"#,
                #"\left😀x\right)"#, #"\color{😀ff0000}{x}"#,
                #"\color{notacolor}{x}"#, #"\color{#f}{x}"#, #"\color{#ff0000zz}{x}"#,
                String(repeating: "{", count: 100) + "x" + String(repeating: "}", count: 100),
                String(repeating: #"\frac"#, count: 100) + "ab"] {
      let result = await MathRenderer.shared.render(request(tex))
      guard case .failure(.parse) = result else { Issue.record("Expected bounded parse failure"); continue }
    }
  }

  @Test("matrix padding cannot bypass the cell budget")
  func matrixBudget() async {
    let row = Array(repeating: "x", count: 129).joined(separator: "&")
    let rows = ([row] + Array(repeating: "y", count: 126)).joined(separator: #"\\"#)
    let result = await MathRenderer.shared.render(request(#"\begin{matrix}"# + rows + #"\end{matrix}"#))
    guard case .failure(.parse) = result else { Issue.record("Expected matrix budget failure"); return }
  }

  @Test("source, tokens, raster and parameter limits are checked")
  func limits() async {
    #expect(await failure(request("")) == .emptySource)
    #expect(await failure(request(String(repeating: "x", count: 8193))) == .sourceLimit)
    #expect(await failure(request(String(repeating: "x ", count: 2049))) == .tokenLimit)
    #expect(await failure(request(String(repeating: "x+", count: 1000), size: 96)) == .rasterLimit)
    #expect(await failure(request("x", size: .infinity)) == .invalidParameters)
    #expect(await failure(request("x", scale: 0)) == .invalidParameters)
    #expect(await failure(request("x", color: .init(red: .nan, green: 0, blue: 0))) == .invalidParameters)
  }

  @Test("repeated requests share immutable images while scale and color remain distinct")
  func cacheIdentity() async throws {
    let first = try await MathRenderer.shared.render(request("x")).get()
    let again = try await MathRenderer.shared.render(request("x")).get()
    #expect(first.image === again.image)
    let scaled = try await MathRenderer.shared.render(request("x", scale: 3)).get()
    #expect(scaled.image !== first.image)
    #expect(scaled.image.height > first.image.height)
    let colored = try await MathRenderer.shared.render(request("x", color: .init(red: 1, green: 0, blue: 0))).get()
    #expect(colored.image !== first.image)
  }

  @Test("native cache lookup never performs a render on a miss")
  func synchronousLookup() async throws {
    let value = request("cacheLookupUnique_{2026}")
    #expect(MathRenderer.shared.cachedResult(for: value) == nil)
    #expect(MathRenderer.shared.cachedResult(for: value) == nil)
    let rendered = try await MathRenderer.shared.render(value).get()
    let cached = try #require(MathRenderer.shared.cachedResult(for: value)).get()
    #expect(cached.image === rendered.image)
    #expect(request("é") != request("e\u{301}"))
  }

  @Test("concurrent callers receive their own formula results")
  func concurrency() async throws {
    let widths = try await withThrowingTaskGroup(of: CGFloat.self) { group in
      for count in 1...12 {
        group.addTask { try await MathRenderer.shared.render(request(String(repeating: "x", count: count))).get().width }
      }
      var widths: [CGFloat] = []
      for try await width in group { widths.append(width) }
      return widths.sorted()
    }
    #expect(widths.count == 12)
    #expect(Set(widths).count == 12)
  }

  @Test("every streamed prefix and deterministic malformed snippets terminate safely")
  func adversarialInputs() async {
    let examples = [#"\frac{\sqrt{x^2+1}}{1+x}"#, #"\left(\sum_{n=0}^{12}n\right)"#,
                    #"\begin{pmatrix}a&b\\c&d\end{pmatrix}"#,
                    #"\color{#ff0000}{\frac{x}{y}}"#,
                    #"x+\textcolor{#ff0000}{\frac{\sqrt{x}}{y}}"#,
                    #"\left\{\begin{cases}x&x>0\\-x&x<0\end{cases}\right."#]
    for example in examples {
      for length in 0...example.count {
        _ = await MathRenderer.shared.render(request(String(example.prefix(length))))
      }
    }
    var seed: UInt64 = 0x1397
    let fragments = ["x", "1", "+", "-", "=", "{", "}", "[", "]", "^", "_", "&", "(", ")", ".",
                     #"\frac"#, #"\sqrt"#, #"\left"#, #"\right"#, #"\\"#, #"\over"#, #"\limits"#,
                     #"\nolimits"#, #"\begin{matrix}"#, #"\end{matrix}"#, #"\color"#,
                     #"\textcolor"#, #"\colorbox"#, "#ff0000", "😀"]
    for _ in 0..<4096 {
      var source = ""
      for _ in 0..<16 {
        seed = seed &* 6364136223846793005 &+ 1
        source += fragments[Int((seed >> 32) % UInt64(fragments.count))]
      }
      _ = await MathRenderer.shared.render(request(source))
    }
  }

  @Test("nested valid formula combinations preserve renderability")
  func generatedFormulas() async {
    var seed: UInt64 = 0xa738
    func formula(depth: Int) -> String {
      seed = seed &* 6364136223846793005 &+ 1
      guard depth > 0 else { return ["x", "1", #"\alpha"#, #"\pi"#][Int((seed >> 32) % 4)] }
      let choice = Int((seed >> 32) % 10)
      let a = formula(depth: depth - 1)
      switch choice {
      case 0: return #"\frac{"# + a + "}{" + formula(depth: depth - 1) + "}"
      case 1: return #"\sqrt{"# + a + "}"
      case 2: return #"\left("# + a + #"\right)"#
      case 3: return #"\textcolor{#55aaff}{"# + a + "}"
      case 4: return #"\overline{"# + a + "}"
      case 5: return #"\widehat{"# + a + "}"
      case 6: return "{" + a + "}^{" + formula(depth: depth - 1) + "}"
      case 7: return #"\sum_{n=0}^{3}{"# + a + "}"
      case 8: return #"\begin{matrix}"# + a + "&" + formula(depth: depth - 1) + #"\end{matrix}"#
      default: return "{" + a + "}+{" + formula(depth: depth - 1) + "}"
      }
    }
    for _ in 0..<512 {
      let source = formula(depth: 3)
      let result = await MathRenderer.shared.render(request(source))
      if case let .failure(error) = result { Issue.record("Valid formula failed: \(source), \(error)") }
    }
  }

  @Test("color wrappers preserve display fraction metrics")
  func colorMetrics() async throws {
    let plain = try await MathRenderer.shared.render(request(#"\frac{a}{b}"#)).get()
    let prefixed = try await MathRenderer.shared.render(request(#"x+\frac{a}{b}"#)).get()
    for wrapper in ["color", "textcolor", "colorbox"] {
      let colored = try await MathRenderer.shared.render(request("\\" + wrapper + #"{#ff0000}{\frac{a}{b}}"#)).get()
      #expect(abs(plain.ascent - colored.ascent) < 0.5)
      #expect(abs(plain.descent - colored.descent) < 0.5)
      #expect(abs(plain.width - colored.width) < 0.5)
      let afterText = try await MathRenderer.shared.render(request("x+\\" + wrapper + #"{#ff0000}{\frac{a}{b}}"#)).get()
      #expect(abs(prefixed.ascent - afterText.ascent) < 0.5)
      #expect(abs(prefixed.descent - afterText.descent) < 0.5)
    }
  }

  @Test("named and hexadecimal color commands render the same pixels")
  func colorPixels() async throws {
    let named = try await MathRenderer.shared.render(request(#"\color{red}{x}"#)).get()
    let hex = try await MathRenderer.shared.render(request(#"\color{#ff0000}{x}"#)).get()
    #expect(named.image.width == hex.image.width && named.image.height == hex.image.height)
    let namedPixels = try #require(named.image.dataProvider?.data as Data?)
    let hexPixels = try #require(hex.image.dataProvider?.data as Data?)
    #expect(namedPixels == hexPixels)
    let maxima = (0..<4).map { channel in stride(from: channel, to: namedPixels.count, by: 4).map { Int(namedPixels[$0]) }.max() ?? 0 }
    #expect(maxima[0] > 100 && maxima[0] > maxima[1] + 50 && maxima[0] > maxima[2] + 50, "RGBA channel maxima: \(maxima)")
  }

  @Test("cancelled work returns without caching a false success")
  func cancellation() async {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await MathRenderer.shared.render(request("x+cancelled"))
    }
    guard case .failure(.cancelled) = await task.value else {
      Issue.record("Expected cancellation"); return
    }
  }

  @Test("canonically equivalent Unicode source has distinct literal cache identity")
  func literalUnicodeCache() async throws {
    let composed = try await MathRenderer.shared.render(request("é")).get()
    let decomposed = try await MathRenderer.shared.render(request("e\u{301}")).get()
    #expect(composed.image !== decomposed.image)
  }

  private func failure(_ request: MathRenderRequest) async -> MathRenderFailure? {
    if case let .failure(error) = await MathRenderer.shared.render(request) { return error }
    return nil
  }

  private func request(_ tex: String, size: Double = 20, scale: Double = 2,
                       color: MathColor = .init(red: 0, green: 0, blue: 0)) -> MathRenderRequest {
    .init(tex: tex, display: true, pointSize: size, scale: scale, color: color)
  }
}

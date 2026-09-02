import { fromMarkdown, type Extension, type Options } from "mdast-util-from-markdown"
import { gfmFromMarkdown } from "mdast-util-gfm"
import { gfm } from "micromark-extension-gfm"
import { readMathCandidate } from "../translation2/entities/math"

type SyntaxExtension = NonNullable<Options["extensions"]>[number]
type Construct = Exclude<NonNullable<SyntaxExtension["text"]>[number], unknown[] | undefined>
type State = ReturnType<Construct["tokenize"]>

/** Keep TeX opaque with original source positions. Inline labels retain their
 * identifier spelling; closed display math cannot introduce fake flow blocks. */
export function richMarkdownAst(source: string, mdastExtensions: Extension[] = []) {
  const math: SyntaxExtension = { flow: { 36: { concrete: true, tokenize(effects, ok, nok) {
    const span = readMathCandidate(source, this.now().offset)
    if (!span?.display || (source.slice(span.end).split(/[\r\n]/, 1)[0] ?? "").trim().length) return nok
    let dataOpen = false
    const consume: State = (code) => {
      if (this.now().offset >= span.end) {
        if (dataOpen) effects.exit("data")
        effects.exit("paragraph")
        return ok(code)
      }
      if (code === null) return nok(code)
      if (code === -5 /* CR */ || code === -4 /* LF */ || code === -3 /* CRLF */) {
        if (dataOpen) { effects.exit("data"); dataOpen = false }
        effects.enter("lineEnding")
        effects.consume(code)
        effects.exit("lineEnding")
      } else {
        if (!dataOpen) { effects.enter("data"); dataOpen = true }
        effects.consume(code)
      }
      return consume
    }
    return (code) => {
      // Closed display TeX is opaque flow content. Use a paragraph with literal
      // data children so consumers retain the original source range and choose
      // the existing math block, without an extra persisted AST node kind.
      effects.enter("paragraph")
      return consume(code)
    }
  } } }, text: { 36: { tokenize(effects, ok, nok) {
    let end = 0
    const consume: State = (code) => {
      if (this.now().offset >= end) {
        effects.exit("data")
        return ok(code)
      }
      if (code === null) return nok(code)
      effects.consume(code)
      return consume
    }
    const start: State = (code) => {
      const offset = this.now().offset
      const span = readMathCandidate(source, offset)
      if (!span || /[\r\n]/.test(source.slice(offset, span.end))) return nok(code)
      end = span.end
      effects.enter("data")
      return consume(code)
    }
    return start
  } } } }
  return fromMarkdown(source, { extensions: [gfm(), math], mdastExtensions: [gfmFromMarkdown(), ...mdastExtensions] })
}

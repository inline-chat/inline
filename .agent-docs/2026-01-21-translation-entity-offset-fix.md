# Translation entity offset prompt update summary

## Why
Entity offsets can drift when the translation model interprets indices differently for emoji or non-ASCII characters. The goal is to give the model explicit, per-character indexing guidance so it returns accurate UTF-16 offsets without post-processing, and to avoid invalid JSON payloads for entities.

## What changed
- Updated the indexed text format to include inline Unicode codepoint tags for non-ASCII characters, e.g. `0<emoji>(U+1F6CD)2<vs16>(U+FE0F)3`.
- Added a tiny inline example showing how an emoji consumes two UTF-16 units (offset/length guidance).
- Clarified the prompt so the model returns entities as JSON objects (not strings) and no extra text.
- Allowed the parser to accept either JSON objects/arrays or stringified JSON for entities, with a best-effort substring fallback.

## Files touched
- `server/src/modules/translation/entityConversion.ts`

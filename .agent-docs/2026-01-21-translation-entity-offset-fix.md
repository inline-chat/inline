# Translation entity offset prompt update summary

## Why
Entity offsets can drift when the translation model interprets indices differently for emoji or non-ASCII characters. The goal is to give the model explicit, per-character indexing guidance so it returns accurate UTF-16 offsets without post-processing.

## What changed
- Updated the indexed text format to include inline Unicode codepoint tags for non-ASCII characters, e.g. `0<emoji>(U+1F6CD)2<vs16>(U+FE0F)3`.
- Clarified the prompt to state that the numbers are UTF-16 offsets and the `(U+XXXX)` tags are only for reference.
- Removed the post-processing normalization/fallback logic added earlier.

## Files touched
- `server/src/modules/translation/entityConversion.ts`

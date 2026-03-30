# Plan: Email Rich Text Entities

1. Review existing rich-text entity handling (server + Apple) and identify touch points for email entities, click handling, and mailto suppression. [done]
2. Implement email entity support in shared text processing (InlineKit key + ProcessEntities render/extract + mailto handling + regex detection). [done]
3. Add server-side email detection in markdown parsing and update tests. [done]
4. Update iOS/mac message views + compose to suppress mailto and copy email on tap with toast. [done]
5. Update/extend tests (InlineUI + server) and sanity-check for regressions. [done]

We're implementing video sending in the chat app. The work is done in the current branch (video) and each task is committed before working on next one.

# High-level TODOs

- [x] add to compose
- [x] add to backend
- [x] add thumbnail upload support
- [x] upload from client side
- [x] ensure it's stored in client side cache with thumbnail and associated with message and included in `FullMessage`
- [x] render in message view and include in size calculations for message table view
- [x] ensure quicklook preview is setup correctly
- [x] show duration on the macOS view as a small overlay at top leading edge with a small padding
- [x] context menu option to "save" video which shows a downloading view (if not yet) and success/error alert
- [x] include video thumbnail in the replied to embedded message with a play icon overlaid on it

# Tasks left for later

- [ ] render on iOS (no need for send from iOS yet)
- [ ] show download/upload progress over the video view in message on macos (highly optional)
- [ ] auto play video once downloaded
- [ ] add a setting to auto download videos
- [ ] ensure GIF works too

# The flow and related files

No need to read all these files. Just read anything you feel like is related to your work and move forward.

- apple/InlineMac/Views/Compose/ComposeMenuButton.swift — user picks images/videos/files (NSOpenPanel) and routes to ComposeAppKit delegate.
- apple/InlineMac/Views/Compose/ComposeAppKit.swift — handles drops/paste/picker callbacks, creates FileMediaItem for photos/videos/docs, keeps attachmentItems, updates UI.
- apple/InlineMac/Views/Compose/ComposeAttachments.swift — renders attachment chips (ImageAttachmentView/VideoAttachmentView/DocumentView), supports remove/tap-to-preview for videos.
- apple/InlineMac/Views/Compose/VideoAttachmentView.swift — shows video thumbnail + play icon, first-click Quick Look preview via QLPreviewPanel.
- apple/InlineMac/Views/Compose/Pasteboard.swift — normalizes pasteboard drops into image/file/video attachments.
- apple/InlineKit/Sources/InlineKit/Files/FileCache.swift — saves picked media locally (photos via savePhoto, videos via saveVideo generating thumbnail, documents via saveDocument) into app support cache and writes
  DB rows.
- apple/InlineKit/Sources/InlineKit/Files/MediaHelpers.swift — creates local Photo/Video/Document records with temporary negative IDs, preserves paths/sizes/thumbnail refs.
- apple/InlineKit/Sources/InlineKit/Files/FileUpload.swift — coordinates uploads: compresses photos, builds video metadata + optional thumbnail, posts multipart via ApiClient, tracks progress, updates DB IDs when server
  returns.
- apple/InlineKit/Sources/InlineKit/ApiClient.swift — multipart /uploadFile call; supports video metadata (width/height/duration) and optional thumbnail part; returns photoId/videoId/documentId.
- server/src/methods/uploadFile.ts — API endpoint validating file type/metadata, uploads file, optional video thumbnail first, returns IDs.
- server/src/modules/files/uploadVideo.ts — stores video file + metadata and links optional thumbnail photo.
- apple/InlineKit/Sources/InlineKit/Transactions/Methods/SendMessage.swift — for each attachment waits upload, maps server IDs into InputMedia (.fromPhotoId/.fromVideoId/.fromDocumentId), then invokes Realtime
  sendMessage.
- server/src/functions/messages.sendMessage.ts — inserts message with mediaId, fetches full media, emits updates.
- server/src/realtime/encoders/encodeMessage.ts & encodeVideo.ts — encode Message/Video proto with signed CDN URLs and thumbnail photo.
- apple/InlineKit/Sources/InlineKit/Models/Message.swift & Media.swift — store received proto media, preserve local paths, map thumbnails.
- apple/InlineKit/Sources/InlineKit/Files/FileDownload.swift & FileCache.save\*Download — download missing media when rendering, update localPath, trigger message reload.
- apple/InlineMac/Views/Message/MessageView.swift & apple/InlineMac/Views/Message/Media/NewPhotoView.swift (photo) / upcoming VideoView — render media bubbles and handle tap/preview; size estimates in apple/InlineMac/
  Views/MessageList/MessageSizeCalculator.swift.

# More related files

- InlineKit FullMessage aggregation: `apple/InlineKit/Sources/InlineKit/ViewModels/FullChat.swift` (includes videoInfo + thumbnail in query)
- Message media persistence/upserts: `apple/InlineKit/Sources/InlineKit/Models/Message.swift` (`processMediaAttachments`, message.videoId mapping)
- Video/thumbnail cache & local saves: `apple/InlineKit/Sources/InlineKit/Files/FileCache.swift` (`saveVideo`, `saveVideoDownload`)
- Video upload + ID/thumbnail resolution: `apple/InlineKit/Sources/InlineKit/Files/FileUpload.swift`
- Media helpers/local temp IDs: `apple/InlineKit/Sources/InlineKit/Files/MediaHelpers.swift`
- Message size/render entry points (macOS): `apple/InlineMac/Views/Message/MessageView.swift` and `apple/InlineMac/Views/MessageList/MessageSizeCalculator.swift`
- Existing photo bubble reference for parity: `apple/InlineMac/Views/Message/Media/NewPhotoView.swift`

# Instructions

- Do tasks one step at a time, once done ask for testing and when confirmed it's done, updated the todo list.
- If you need to include any tips for the next agent to work on the next task, append a brief bullet item in the next section.
- The goal is to create a robust video sending and viewing experience end to end. Initially on macOS and later rendering on iOS as well. Sending from iOS is out of scope of current task.
- UI is minimal, and follows our other views.
- Feature should remain simple, reliable, and robust and follow the best practices and patterns we already have for sending files and photos and rendering.
- Some steps may have been completely or partially done from previous steps work already.
- If you notice any other files you may need for next steps, include them in the section above and update this file.
- There will not be a photo AND a video at the same time in one message. Only one media item (document, photo or video) will be present.

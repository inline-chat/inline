/**
 * The media viewer's chunk: its model and view. Loaded on the first photo
 * or video opened (`MediaViewerHost.open`); nothing imports it statically.
 */

export { MediaViewer } from "./MediaViewer"
export { MediaViewerModel, viewerItems } from "./media-viewer"

export type MediaViewerChunk = typeof import("./media-viewer-chunk")

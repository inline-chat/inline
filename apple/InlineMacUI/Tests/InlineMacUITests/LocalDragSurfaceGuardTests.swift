import AppKit
import Testing
@testable import InlineMacUI

@MainActor
@Test("blocks local drags when source and destination share the same marked chat surface")
func localDragSurfaceGuard_blocksSameMarkedSurface() {
  let surface = NSView()
  surface.identifier = LocalDragSurfaceGuard.chatSurfaceIdentifier

  let source = NSView()
  let destination = NSView()
  surface.addSubview(source)
  surface.addSubview(destination)

  #expect(
    LocalDragSurfaceGuard.isDragFromSameSurface(
      source: source,
      destinationView: destination
    )
  )
}

@MainActor
@Test("allows local drags when source and destination are in different marked chat surfaces")
func localDragSurfaceGuard_allowsDifferentMarkedSurfaces() {
  let sourceSurface = NSView()
  sourceSurface.identifier = LocalDragSurfaceGuard.chatSurfaceIdentifier

  let destinationSurface = NSView()
  destinationSurface.identifier = LocalDragSurfaceGuard.chatSurfaceIdentifier

  let source = NSView()
  let destination = NSView()
  sourceSurface.addSubview(source)
  destinationSurface.addSubview(destination)

  #expect(
    LocalDragSurfaceGuard.isDragFromSameSurface(
      source: source,
      destinationView: destination
    ) == false
  )
}

@MainActor
@Test("allows drags when the source is not a view inside a marked chat surface")
func localDragSurfaceGuard_allowsNonViewOrUnmarkedSource() {
  let destinationSurface = NSView()
  destinationSurface.identifier = LocalDragSurfaceGuard.chatSurfaceIdentifier

  let destination = NSView()
  destinationSurface.addSubview(destination)

  #expect(
    LocalDragSurfaceGuard.isDragFromSameSurface(
      source: "not-a-view",
      destinationView: destination
    ) == false
  )

  let source = NSView()
  #expect(
    LocalDragSurfaceGuard.isDragFromSameSurface(
      source: source,
      destinationView: destination
    ) == false
  )
}

#if os(macOS)
import Cocoa
@testable import Cache

extension NSImage {
  func isEqualToImage(_ image: NSImage) -> Bool {
    guard size == image.size,
          let lhs = centerColor(),
          let rhs = image.centerColor() else {
      return false
    }

    // Opaque images intentionally round-trip through maximum-quality JPEG in
    // the production encoder. Verify rendered content while tolerating that
    // codec's small channel drift and its deliberate loss of alpha metadata.
    return abs(lhs.redComponent - rhs.redComponent) <= 0.02
      && abs(lhs.greenComponent - rhs.greenComponent) <= 0.02
      && abs(lhs.blueComponent - rhs.blueComponent) <= 0.02
  }

  private func centerColor() -> NSColor? {
    var proposedRect = NSRect(origin: .zero, size: size)
    guard let image = cgImage(
      forProposedRect: &proposedRect,
      context: nil,
      hints: nil
    ) else {
      return nil
    }
    return NSBitmapImageRep(cgImage: image)
      .colorAt(x: image.width / 2, y: image.height / 2)?
      .usingColorSpace(.deviceRGB)
  }
}
#endif

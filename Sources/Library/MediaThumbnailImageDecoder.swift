import CoreGraphics
import Foundation
import ImageIO

/// JPEG I/O and eager decode must not run while SwiftUI computes a card body.
enum MediaThumbnailImageDecoder {
    static func image(at url: URL?) async -> CGImage? {
        guard let url, !Task.isCancelled else { return nil }
        let worker = Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            guard !Task.isCancelled else { return nil }
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            return CGImageSourceCreateImageAtIndex(source, 0, options)
        }
        // Wait for ImageIO to return even after cancellation, so the caller keeps
        // its shared work permit until the actual decode has stopped.
        let image = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else { return nil }
        return image
    }
}

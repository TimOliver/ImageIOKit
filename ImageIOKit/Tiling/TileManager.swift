//
//  TileManager.swift
//  ImageIOKit
//
//  On-demand tile decoder with NSCache-backed storage.
//  For JPEG sources, each tile is decoded independently via libjpeg
//  region decode. For all other formats, the full image is decoded
//  once via ImageIO (cached in ImageSource) and tiles are extracted
//  via CGImage.cropping(to:).
//

import Foundation
import CoreGraphics
import UIKit

/// Manages tile-based image decoding and caching for large images.
public final class TileManager {

    /// The image source to decode tiles from.
    public let imageSource: ImageSource

    /// The tile grid geometry.
    public let grid: TileGrid

    // NSCache for decoded tile images, keyed by "col,row".
    private let cache = NSCache<NSString, UIImage>()

    /// Creates a tile manager for the given image source.
    /// - Parameters:
    ///   - imageSource: The loaded image source to tile.
    ///   - tileSize: The size of each tile. Defaults to 512x512.
    ///   - cacheLimit: Maximum number of decoded tiles to keep in cache.
    public init(imageSource: ImageSource, tileSize: CGSize = CGSize(width: 512, height: 512),
                cacheLimit: Int = 50) {
        self.imageSource = imageSource
        self.grid = TileGrid(imageSize: imageSource.imageSize, tileSize: tileSize)
        cache.countLimit = cacheLimit
    }

    /// Returns the decoded tile image, using the cache if available.
    /// For formats with native region decode, decodes only the tile region.
    /// For others, extracts the tile from a full-resolution decode.
    /// - Parameter descriptor: The tile to decode.
    /// - Returns: The decoded tile image, or `nil` on failure.
    public func tile(at descriptor: TileDescriptor) -> UIImage? {
        let key = cacheKey(for: descriptor)

        // Check cache first
        if let cached = cache.object(forKey: key) {
            return cached
        }

        // Decode the tile
        guard let image = decodeTile(descriptor) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// Returns the tiles visible in the given viewport.
    /// - Parameter viewport: The visible rect in image pixel coordinates.
    /// - Returns: Array of (descriptor, image) pairs for visible tiles.
    public func visibleTiles(in viewport: CGRect) -> [(TileDescriptor, UIImage)] {
        let descriptors = grid.tiles(in: viewport)
        return descriptors.compactMap { desc in
            guard let image = tile(at: desc) else { return nil }
            return (desc, image)
        }
    }

    /// Asynchronously decodes tiles for the given viewport.
    /// - Parameters:
    ///   - viewport: The visible rect in image pixel coordinates.
    ///   - completion: Called on the main queue with decoded (descriptor, image) pairs.
    public func loadVisibleTiles(in viewport: CGRect,
                                  completion: @escaping ([(TileDescriptor, UIImage)]) -> Void) {
        let descriptors = grid.tiles(in: viewport)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let results: [(TileDescriptor, UIImage)]
            if self.imageSource.isRegionDecodable {
                // Parallel: each tile gets its own independent codec context
                var pairs = [(TileDescriptor, UIImage)?](repeating: nil, count: descriptors.count)
                DispatchQueue.concurrentPerform(iterations: descriptors.count) { i in
                    if let image = self.tile(at: descriptors[i]) {
                        pairs[i] = (descriptors[i], image)
                    }
                }
                results = pairs.compactMap { $0 }
            } else {
                // Serial: full decode is cached in ImageSource
                results = descriptors.compactMap { desc in
                    guard let image = self.tile(at: desc) else { return nil }
                    return (desc, image)
                }
            }

            DispatchQueue.main.async {
                completion(results)
            }
        }
    }

    /// Clears all cached tiles.
    public func clearCache() {
        cache.removeAllObjects()
    }

    // MARK: - Private

    private func cacheKey(for descriptor: TileDescriptor) -> NSString {
        "\(descriptor.column),\(descriptor.row)" as NSString
    }

    private func decodeTile(_ descriptor: TileDescriptor) -> UIImage? {
        // Use native region decode if available
        if imageSource.isRegionDecodable {
            return imageSource.decodeRegion(descriptor.rect)
        }

        // Otherwise, extract tile from full-resolution CGImage (cached in ImageSource)
        guard let fullImage = imageSource.decodeFullCGImage(),
              let cropped = fullImage.cropping(to: descriptor.rect) else { return nil }
        return UIImage(cgImage: cropped)
    }
}

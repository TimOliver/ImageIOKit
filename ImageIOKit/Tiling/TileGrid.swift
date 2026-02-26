//
//  TileGrid.swift
//  ImageIOKit
//
//  Divides a full image into a grid of tiles and maps viewport
//  rectangles to the set of tiles that need to be decoded.
//

import Foundation
import CoreGraphics

/// A grid that divides a full image into equally-sized tiles.
/// Handles edge tiles that may be smaller than the standard tile size.
public struct TileGrid {

    /// The full image size in pixels.
    public let imageSize: CGSize

    /// The standard tile size in pixels.
    public let tileSize: CGSize

    /// Number of tile columns.
    public let columns: Int

    /// Number of tile rows.
    public let rows: Int

    /// Total number of tiles.
    public var tileCount: Int { columns * rows }

    /// Creates a tile grid for the given image and tile size.
    /// - Parameters:
    ///   - imageSize: The full image dimensions in pixels.
    ///   - tileSize: The desired tile dimensions. Defaults to 512x512.
    public init(imageSize: CGSize, tileSize: CGSize = CGSize(width: 512, height: 512)) {
        self.imageSize = imageSize
        self.tileSize = tileSize
        self.columns = max(1, Int(ceil(imageSize.width / tileSize.width)))
        self.rows = max(1, Int(ceil(imageSize.height / tileSize.height)))
    }

    /// Returns the tile descriptor for the given grid position.
    /// - Parameters:
    ///   - column: The zero-based column index (left to right).
    ///   - row: The zero-based row index (top to bottom).
    /// - Returns: The tile descriptor, or `nil` if the position is out of bounds.
    public func tile(column: Int, row: Int) -> TileDescriptor? {
        guard column >= 0, column < columns, row >= 0, row < rows else { return nil }

        let x = CGFloat(column) * tileSize.width
        let y = CGFloat(row) * tileSize.height
        let w = min(tileSize.width, imageSize.width - x)
        let h = min(tileSize.height, imageSize.height - y)

        return TileDescriptor(column: column, row: row,
                              rect: CGRect(x: x, y: y, width: w, height: h))
    }

    /// Returns all tile descriptors in the grid.
    public var allTiles: [TileDescriptor] {
        var tiles: [TileDescriptor] = []
        tiles.reserveCapacity(tileCount)
        for row in 0..<rows {
            for col in 0..<columns {
                if let t = tile(column: col, row: row) {
                    tiles.append(t)
                }
            }
        }
        return tiles
    }

    /// Returns the tiles that intersect the given viewport rect.
    /// Use this to determine which tiles need to be decoded for the current visible area.
    /// - Parameter viewport: The visible rect in image pixel coordinates.
    /// - Returns: The tile descriptors that overlap the viewport.
    public func tiles(in viewport: CGRect) -> [TileDescriptor] {
        let minCol = max(0, Int(floor(viewport.minX / tileSize.width)))
        let maxCol = min(columns - 1, Int(floor(viewport.maxX / tileSize.width)))
        let minRow = max(0, Int(floor(viewport.minY / tileSize.height)))
        let maxRow = min(rows - 1, Int(floor(viewport.maxY / tileSize.height)))

        guard minCol <= maxCol, minRow <= maxRow else { return [] }

        var result: [TileDescriptor] = []
        result.reserveCapacity((maxCol - minCol + 1) * (maxRow - minRow + 1))

        for row in minRow...maxRow {
            for col in minCol...maxCol {
                if let t = tile(column: col, row: row) {
                    result.append(t)
                }
            }
        }
        return result
    }
}

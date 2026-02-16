//
//  TileDescriptor.swift
//  ImageIOKit
//
//  Describes a single tile in a tiled image display, including
//  its grid position and pixel-coordinate rect within the full image.
//

import Foundation
import CoreGraphics

/// Identifies a single tile in a tile grid, with its position
/// and corresponding region in the full image's pixel coordinates.
public struct TileDescriptor: Hashable {
    /// Column index (0-based, left to right).
    public let column: Int
    /// Row index (0-based, top to bottom).
    public let row: Int
    /// The tile's region in full-image pixel coordinates.
    public let rect: CGRect

    public init(column: Int, row: Int, rect: CGRect) {
        self.column = column
        self.row = row
        self.rect = rect
    }
}

extension TileDescriptor: CustomStringConvertible {
    public var description: String {
        "Tile(\(column),\(row)) [\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height))]"
    }
}

//
//  TileGridTests.swift
//  ImageIOKitTests
//

import XCTest
@testable import ImageIOKitExample

final class TileGridTests: XCTestCase {

    // MARK: - Grid Dimensions

    func testGridDimensionsEvenDivision() {
        let grid = TileGrid(imageSize: CGSize(width: 1024, height: 512),
                            tileSize: CGSize(width: 256, height: 256))
        XCTAssertEqual(grid.columns, 4)
        XCTAssertEqual(grid.rows, 2)
        XCTAssertEqual(grid.tileCount, 8)
    }

    func testGridDimensionsUnevenDivision() {
        let grid = TileGrid(imageSize: CGSize(width: 1000, height: 700),
                            tileSize: CGSize(width: 512, height: 512))
        XCTAssertEqual(grid.columns, 2) // ceil(1000/512) = 2
        XCTAssertEqual(grid.rows, 2)    // ceil(700/512) = 2
        XCTAssertEqual(grid.tileCount, 4)
    }

    func testSingleTileGrid() {
        let grid = TileGrid(imageSize: CGSize(width: 100, height: 100),
                            tileSize: CGSize(width: 512, height: 512))
        XCTAssertEqual(grid.columns, 1)
        XCTAssertEqual(grid.rows, 1)
        XCTAssertEqual(grid.tileCount, 1)
    }

    func testExactlyOneTileWide() {
        let grid = TileGrid(imageSize: CGSize(width: 512, height: 512),
                            tileSize: CGSize(width: 512, height: 512))
        XCTAssertEqual(grid.columns, 1)
        XCTAssertEqual(grid.rows, 1)
    }

    // MARK: - Tile Descriptors

    func testTileAtValidPosition() {
        let grid = TileGrid(imageSize: CGSize(width: 1024, height: 1024),
                            tileSize: CGSize(width: 512, height: 512))

        let tile = grid.tile(column: 0, row: 0)
        XCTAssertNotNil(tile)
        XCTAssertEqual(tile?.column, 0)
        XCTAssertEqual(tile?.row, 0)
        XCTAssertEqual(tile?.rect, CGRect(x: 0, y: 0, width: 512, height: 512))

        let tile11 = grid.tile(column: 1, row: 1)
        XCTAssertNotNil(tile11)
        XCTAssertEqual(tile11?.rect, CGRect(x: 512, y: 512, width: 512, height: 512))
    }

    func testTileAtInvalidPosition() {
        let grid = TileGrid(imageSize: CGSize(width: 1024, height: 1024),
                            tileSize: CGSize(width: 512, height: 512))
        XCTAssertNil(grid.tile(column: -1, row: 0))
        XCTAssertNil(grid.tile(column: 0, row: -1))
        XCTAssertNil(grid.tile(column: 2, row: 0))
        XCTAssertNil(grid.tile(column: 0, row: 2))
    }

    func testEdgeTileSizes() {
        // Image doesn't divide evenly — edge tiles are smaller
        let grid = TileGrid(imageSize: CGSize(width: 700, height: 500),
                            tileSize: CGSize(width: 512, height: 512))

        let topLeft = grid.tile(column: 0, row: 0)
        XCTAssertEqual(topLeft?.rect.width, 512)
        XCTAssertEqual(topLeft?.rect.height, 500)  // Clamped to image height

        let topRight = grid.tile(column: 1, row: 0)
        XCTAssertEqual(topRight?.rect.width, 188)   // 700 - 512 = 188
        XCTAssertEqual(topRight?.rect.height, 500)
    }

    // MARK: - All Tiles

    func testAllTilesCount() {
        let grid = TileGrid(imageSize: CGSize(width: 1024, height: 768),
                            tileSize: CGSize(width: 256, height: 256))
        let allTiles = grid.allTiles
        XCTAssertEqual(allTiles.count, grid.tileCount)
        XCTAssertEqual(allTiles.count, 4 * 3)
    }

    func testAllTilesCoverFullImage() {
        let grid = TileGrid(imageSize: CGSize(width: 700, height: 500),
                            tileSize: CGSize(width: 256, height: 256))
        let tiles = grid.allTiles

        // Every tile rect should be within the image bounds
        let imageBounds = CGRect(origin: .zero, size: grid.imageSize)
        for tile in tiles {
            XCTAssertTrue(imageBounds.contains(tile.rect),
                          "Tile \(tile) extends outside image bounds")
        }

        // Union of all tile rects should cover the entire image
        let union = tiles.reduce(CGRect.null) { $0.union($1.rect) }
        XCTAssertEqual(union.origin.x, 0, accuracy: 0.5)
        XCTAssertEqual(union.origin.y, 0, accuracy: 0.5)
        XCTAssertEqual(union.width, 700, accuracy: 0.5)
        XCTAssertEqual(union.height, 500, accuracy: 0.5)
    }

    // MARK: - Viewport Queries

    func testTilesInFullImageViewport() {
        let grid = TileGrid(imageSize: CGSize(width: 1024, height: 1024),
                            tileSize: CGSize(width: 512, height: 512))
        let allViewport = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let tiles = grid.tiles(in: allViewport)
        XCTAssertEqual(tiles.count, grid.tileCount)
    }

    func testTilesInPartialViewport() {
        let grid = TileGrid(imageSize: CGSize(width: 1024, height: 1024),
                            tileSize: CGSize(width: 512, height: 512))
        // Viewport covering only top-left tile
        let viewport = CGRect(x: 0, y: 0, width: 256, height: 256)
        let tiles = grid.tiles(in: viewport)
        XCTAssertEqual(tiles.count, 1)
        XCTAssertEqual(tiles.first?.column, 0)
        XCTAssertEqual(tiles.first?.row, 0)
    }

    func testTilesInViewportSpanningMultipleTiles() {
        let grid = TileGrid(imageSize: CGSize(width: 2048, height: 2048),
                            tileSize: CGSize(width: 512, height: 512))
        // Viewport that overlaps 4 tiles (center area)
        let viewport = CGRect(x: 256, y: 256, width: 512, height: 512)
        let tiles = grid.tiles(in: viewport)
        // Should overlap tiles at (0,0), (1,0), (0,1), (1,1)
        XCTAssertEqual(tiles.count, 4)
    }

    func testTilesInOutOfBoundsViewport() {
        let grid = TileGrid(imageSize: CGSize(width: 1024, height: 1024),
                            tileSize: CGSize(width: 512, height: 512))
        let viewport = CGRect(x: 2000, y: 2000, width: 100, height: 100)
        let tiles = grid.tiles(in: viewport)
        XCTAssertTrue(tiles.isEmpty)
    }

    // MARK: - TileDescriptor

    func testTileDescriptorDescription() {
        let tile = TileDescriptor(column: 2, row: 3,
                                  rect: CGRect(x: 1024, y: 1536, width: 512, height: 512))
        let desc = tile.description
        XCTAssertTrue(desc.contains("2"))
        XCTAssertTrue(desc.contains("3"))
    }

    func testTileDescriptorHashable() {
        let tile1 = TileDescriptor(column: 0, row: 0, rect: CGRect(x: 0, y: 0, width: 512, height: 512))
        let tile2 = TileDescriptor(column: 0, row: 0, rect: CGRect(x: 0, y: 0, width: 512, height: 512))
        let tile3 = TileDescriptor(column: 1, row: 0, rect: CGRect(x: 512, y: 0, width: 512, height: 512))

        XCTAssertEqual(tile1, tile2)
        XCTAssertNotEqual(tile1, tile3)

        var set = Set<TileDescriptor>()
        set.insert(tile1)
        set.insert(tile2)
        XCTAssertEqual(set.count, 1)
        set.insert(tile3)
        XCTAssertEqual(set.count, 2)
    }
}

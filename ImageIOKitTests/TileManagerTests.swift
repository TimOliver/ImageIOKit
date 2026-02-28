//
//  TileManagerTests.swift
//  ImageIOKitTests
//

import XCTest
@testable import ImageIOKitExample

final class TileManagerTests: XCTestCase {

    // MARK: - Helpers

    private func makeSource(for format: ImageSampleData.Format) -> ImageSource {
        let url = ImageSampleData.urlForTestImage(with: format)
        guard let source = ImageSource(url: url) else {
            fatalError("Failed to create ImageSource for \(format)")
        }
        return source
    }

    // MARK: - Init

    func testTileManagerInit() {
        let source = makeSource(for: .jpeg)
        let manager = TileManager(imageSource: source)
        XCTAssertEqual(manager.grid.tileSize, CGSize(width: 512, height: 512))
        XCTAssertGreaterThan(manager.grid.tileCount, 0)
    }

    func testTileManagerCustomTileSize() {
        let source = makeSource(for: .jpeg)
        let manager = TileManager(imageSource: source,
                                  tileSize: CGSize(width: 256, height: 256))
        XCTAssertEqual(manager.grid.tileSize, CGSize(width: 256, height: 256))
        // Smaller tiles = more tiles
        let defaultManager = TileManager(imageSource: source)
        XCTAssertGreaterThan(manager.grid.tileCount, defaultManager.grid.tileCount)
    }

    // MARK: - Tile Decode (JPEG — region decode path)

    func testTileDecodeJPEG() {
        let source = makeSource(for: .jpeg)
        XCTAssertTrue(source.isRegionDecodable)

        let manager = TileManager(imageSource: source)
        guard let firstTile = manager.grid.tile(column: 0, row: 0) else {
            XCTFail("No tiles in grid")
            return
        }

        let image = manager.tile(at: firstTile)
        XCTAssertNotNil(image, "JPEG tile decode should succeed via region decode")
    }

    // MARK: - Tile Decode (Non-JPEG — CGImage.cropping path)

    func testTileDecodeNonJPEG() {
        let source = makeSource(for: .png)
        XCTAssertFalse(source.isRegionDecodable)

        let manager = TileManager(imageSource: source)
        guard let firstTile = manager.grid.tile(column: 0, row: 0) else {
            XCTFail("No tiles in grid")
            return
        }

        let image = manager.tile(at: firstTile)
        XCTAssertNotNil(image, "Non-JPEG tile decode should succeed via crop")
    }

    // MARK: - Tile Decode All Formats

    func testTileDecodeAllFormats() {
        for format in ImageSampleData.Format.allCases {
            autoreleasepool {
                let source = makeSource(for: format)
                let manager = TileManager(imageSource: source)
                guard let firstTile = manager.grid.tile(column: 0, row: 0) else {
                    XCTFail("No tiles for \(format)")
                    return
                }

                let image = manager.tile(at: firstTile)
                XCTAssertNotNil(image, "Tile decode failed for \(format)")
            }
        }
    }

    // MARK: - Caching

    func testTileCaching() {
        let source = makeSource(for: .jpeg)
        let manager = TileManager(imageSource: source)
        guard let tile = manager.grid.tile(column: 0, row: 0) else {
            XCTFail("No tiles")
            return
        }

        let first = manager.tile(at: tile)
        let second = manager.tile(at: tile)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        // Same UIImage from cache
        XCTAssertTrue(first === second, "Second request should return cached tile")
    }

    func testClearCache() {
        let source = makeSource(for: .jpeg)
        let manager = TileManager(imageSource: source)
        guard let tile = manager.grid.tile(column: 0, row: 0) else {
            XCTFail("No tiles")
            return
        }

        let first = manager.tile(at: tile)
        XCTAssertNotNil(first)
        manager.clearCache()
        let second = manager.tile(at: tile)
        XCTAssertNotNil(second)
        // After cache clear, should be a different object
        XCTAssertFalse(first === second,
                        "After clearCache, tile should be re-decoded (new object)")
    }

    // MARK: - Visible Tiles

    func testVisibleTilesSync() {
        let source = makeSource(for: .jpeg)
        let manager = TileManager(imageSource: source,
                                  tileSize: CGSize(width: 512, height: 512))
        // Viewport covering top-left portion
        let viewport = CGRect(x: 0, y: 0, width: 600, height: 600)
        let tiles = manager.visibleTiles(in: viewport)
        XCTAssertFalse(tiles.isEmpty, "Should have visible tiles")
        for (desc, image) in tiles {
            XCTAssertTrue(viewport.intersects(desc.rect),
                          "Tile \(desc) should intersect viewport")
            XCTAssertNotNil(image)
        }
    }

    func testVisibleTilesEmptyViewport() {
        let source = makeSource(for: .jpeg)
        let manager = TileManager(imageSource: source)
        let viewport = CGRect(x: 99999, y: 99999, width: 1, height: 1)
        let tiles = manager.visibleTiles(in: viewport)
        XCTAssertTrue(tiles.isEmpty)
    }

    // MARK: - Async Tile Loading

    func testLoadVisibleTilesAsync() {
        let source = makeSource(for: .jpeg)
        let manager = TileManager(imageSource: source,
                                  tileSize: CGSize(width: 512, height: 512))
        let viewport = CGRect(x: 0, y: 0, width: 600, height: 600)

        let expectation = expectation(description: "Async tiles loaded")
        manager.loadVisibleTiles(in: viewport) { tiles in
            XCTAssertFalse(tiles.isEmpty, "Async load should return tiles")
            for (_, image) in tiles {
                XCTAssertNotNil(image)
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 30.0)
    }

    func testLoadVisibleTilesAsyncNonJPEG() {
        let source = makeSource(for: .webp)
        let manager = TileManager(imageSource: source,
                                  tileSize: CGSize(width: 512, height: 512))
        let viewport = CGRect(x: 0, y: 0, width: 600, height: 600)

        let expectation = expectation(description: "Async non-JPEG tiles loaded")
        manager.loadVisibleTiles(in: viewport) { tiles in
            XCTAssertFalse(tiles.isEmpty)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 30.0)
    }
}

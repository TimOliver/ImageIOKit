//
//  ImageDecoderError.swift
//  ImageIOKit
//

import Foundation

/// Errors produced by image decode operations.
public enum ImageDecoderError: Error {
    /// The input data is not a valid image.
    case invalidData
    /// The decode operation failed. The associated string provides details.
    case decodeFailed(String)
    /// The requested operation is not supported.
    case unsupportedOperation
    /// The provided decode options are invalid (e.g., crop rect out of bounds).
    case invalidOptions(String)
}

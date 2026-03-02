//
//  ImageEncoderError.swift
//  ImageIOKit
//

import Foundation

/// Errors produced by image encode operations.
public enum ImageEncoderError: Error {
    /// The encode operation failed. The associated string provides details.
    case encodeFailed(String)
}

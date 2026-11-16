//
//  FacePoint.swift
//  FaceBeauty
//
//  Created by David Sherlock on 2026.
//

import CoreGraphics
import Foundation

/// A normalized point: `x`,`y` in `0…1` from the top-left of the frame.
///
/// The package owns its own point type (rather than depend on a host's) so it
/// stays a self-contained leaf. It is Codable-compatible with any `{x, y}`
/// point, so an embedded track round-trips through a host document.
public struct FacePoint: Codable, Equatable, Hashable, Sendable {
    public var x: CGFloat
    public var y: CGFloat

    public init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }
}

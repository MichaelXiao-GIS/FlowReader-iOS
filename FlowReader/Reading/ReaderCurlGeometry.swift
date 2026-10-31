import Foundation
import CoreGraphics
import simd

/// A continuous paper bend driven by a two-dimensional grab point. Coordinates
/// are canonical: the page's free edge is on the right, before mirroring a back turn.
struct ReaderCurlGeometry {
    var pageSize: CGSize
    var anchor: CGPoint
    var finger: CGPoint

    var progress: CGFloat {
        min(1, max(0, (anchor.x - finger.x) / max(1, anchor.x * 2)))
    }

    var radius: CGFloat {
        let distance = hypot(anchor.x - finger.x, anchor.y - finger.y)
        let envelope = min(1, max(0, (1 - progress) * 7))
        return min(pageSize.width * 0.16, distance / .pi * 0.7) * envelope
    }

    struct Sample: Equatable {
        let position: SIMD3<Float>
        let angle: Float
    }

    /// CPU reference for geometry tests; the same formula runs per vertex in Metal.
    func sample(_ point: CGPoint) -> Sample {
        let a = SIMD2<Float>(Float(anchor.x), Float(anchor.y))
        let f = SIMD2<Float>(Float(finger.x), Float(finger.y))
        let p = SIMD2<Float>(Float(point.x), Float(point.y))
        let distance = simd_length(a - f)
        guard distance > 0.001 else { return Sample(position: SIMD3(p.x, p.y, 0), angle: 0) }
        let normal = (a - f) / distance
        let activation = min(1, distance / 12)
        let flexibility = 0.78 + 0.44 * min(1, abs(p.y - a.y) / max(1, Float(pageSize.height)))
        let r = Float(radius) * flexibility
        let middle = (a + f) * 0.5
        let fold = middle - normal * (.pi * r * 0.5)
        let d = simd_dot(p - fold, normal)
        guard d > 0 else { return Sample(position: SIMD3(p.x, p.y, 0), angle: 0) }
        let angle: Float
        let along: Float
        let lift: Float
        if r < 0.01 {
            angle = .pi; along = -d; lift = 0
        } else if d < .pi * r {
            angle = d / r; along = r * sin(angle); lift = r * (1 - cos(angle))
        } else {
            angle = .pi; along = -(d - .pi * r); lift = 2 * r
        }
        let bent = p + normal * (along - d)
        let position = p + (bent - p) * activation
        return Sample(position: SIMD3(position.x, position.y, lift * activation), angle: angle * activation)
    }

    static func shouldCommit(translation: CGPoint, velocity: CGPoint, pageWidth: CGFloat, direction: Int) -> Bool {
        let travel = -translation.x * CGFloat(direction)
        let speed = -velocity.x * CGFloat(direction)
        if speed < -450 { return false }
        return travel > max(38, pageWidth * 0.28) || (travel > 18 && speed > 580)
    }
}

struct ReaderCurlPageTurn: Equatable {
    let target: Int
    let front: Int
    let back: Int
    let basePages: [Int]

    init?(index: Int, direction: Int, pageCount: Int, doublePage: Bool) {
        guard index >= 0, index < pageCount, direction == -1 || direction == 1 else { return nil }
        let current = doublePage ? index - index % 2 : index
        let target = current + direction * (doublePage ? 2 : 1)
        guard target >= 0, target < pageCount else { return nil }
        self.target = target
        front = doublePage && direction > 0 ? current + 1 : current
        back = doublePage ? (direction > 0 ? target : target + 1) : front
        basePages = doublePage ? (direction > 0 ? [current, target + 1] : [target, current + 1]) : [target]
    }
}

/// Exactly five float4 values: shared with ReaderCurl.metal.
struct ReaderCurlUniforms {
    var viewportAndPage: SIMD4<Float>
    var anchorAndFinger: SIMD4<Float>
    var placement: SIMD4<Float> // page origin X, direction, radius, progress
    var paper: SIMD4<Float>
    var options: SIMD4<Float> // real reverse-side page, reserved
}

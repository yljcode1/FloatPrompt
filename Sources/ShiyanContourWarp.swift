import Foundation
import CoreImage

/// App-owned bounded inverse warp: move cheek contours without shrinking the entire face.
/// Uses pixel-space distances, so portrait aspect ratio does not distort the falloff.
struct ShiyanContourWarp {
    private static let source = """
    float falloff(vec2 p, vec2 c, float radius) {
        float t = clamp(length(p-c) / max(radius, 1.0), 0.0, 1.0);
        float v = 1.0-t*t;
        return v*v;
    }
    kernel vec2 shiyanContour(vec2 lj, vec2 rj, vec2 le, vec2 re, vec2 mouth, vec2 nose,
                             float span, float mouthWidth, float slim, float eyes, float noseAmount) {
        vec2 p = destCoord();
        vec2 axis = normalize(re-le);
        float radius = span*0.78;
        float lipDistance = length((p-mouth)/vec2(max(mouthWidth*0.72,span*0.3),span*0.27));
        float mouthProtect = smoothstep(0.75,1.35,lipDistance);
        float eyeProtect = 1.0-max(falloff(p,le,span*0.46),falloff(p,re,span*0.46));
        float wl = falloff(p,lj,radius);
        float wr = falloff(p,rj,radius);
        float direction = dot(rj-lj,axis) >= 0.0 ? 1.0 : -1.0;
        vec2 cheekShift = axis * direction * (wl-wr) * span * 0.14 * slim * mouthProtect * eyeProtect;
        vec2 q = p-cheekShift;
        vec2 eyeOffset = (p-le)*falloff(p,le,span*0.43)+(p-re)*falloff(p,re,span*0.43);
        q -= eyeOffset * 0.22 * eyes;
        float noseMask = falloff(p,nose,span*0.34) * mouthProtect;
        q += axis * dot(p-nose,axis) * noseMask * 0.20 * noseAmount;
        return q;
    }
    """
    private static let kernel = CIWarpKernel(source: source)
    static func apply(_ image: CIImage, leftJaw: CGPoint, rightJaw: CGPoint, leftEye: CGPoint, rightEye: CGPoint, mouth: CGPoint, nose: CGPoint, eyeSpan: CGFloat, mouthWidth: CGFloat, slim: Double, eyes: Double, noseAmount: Double) -> CIImage? {
        guard let kernel, eyeSpan > 4, hypot(leftEye.x-rightEye.x,leftEye.y-rightEye.y) > 4 else { return nil }
        func vector(_ p: CGPoint) -> CIVector { CIVector(x: p.x, y: p.y) }
        let args: [Any] = [vector(leftJaw),vector(rightJaw),vector(leftEye),vector(rightEye),vector(mouth),vector(nose),eyeSpan,mouthWidth,slim,eyes,noseAmount]
        let margin = eyeSpan * 0.2 + 2
        return kernel.apply(extent: image.extent, roiCallback: { _, rect in rect.insetBy(dx: -margin, dy: -margin) }, image: image.clampedToExtent(), arguments: args)?.cropped(to: image.extent)
    }
}

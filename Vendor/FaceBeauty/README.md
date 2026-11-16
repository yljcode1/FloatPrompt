# swift-face-beauty

On-device, license-clean **face beautification** for photos and video — no
generative model, no restrictive weights. Vision tracks facial landmarks; Core
Image applies the effect. One builder is used for both live preview and export.

## What it does

- **Enlarge eyes** — outward `CIBumpDistortion` at each eye center.
- **Slim face** — inward bumps at the jaw contour.
- **Brighten eyes** — localized exposure lift, masked to the eyes.
- **Whiten teeth** — localized brighten + desaturate, masked to the mouth.

All amounts are `0…1` and stack. Because it's geometric warps + masked colour
(not a GAN), it's fully on-device, real-time, and free of the licensing and
deepfake concerns that block face-*swap* models.

## Usage

```swift
import FaceBeauty

// 1. Track landmarks through the video (once, cacheable).
let keyframes = try await FaceLandmarkTracker.track(videoURL: url)

// 2. Configure the pass.
let beauty = FaceBeauty(eyeEnlarge: 0.4, faceSlim: 0.2,
                        eyeBrighten: 0.3, teethWhiten: 0.4, keyframes: keyframes)

// 3. Apply per frame in your Core Image pipeline (source space, before reframe).
if let filter = FaceBeautyFilter(beauty: beauty) {
    let out = filter.apply(sourceImage, at: sourceTime, sourceSize: size)
}
```

`FaceBeauty` is `Codable`, so a host document can persist the track and amounts.

## Requirements

macOS 26 / iOS 26, Swift 6.2.

## License

MIT — see [LICENSE](LICENSE).

Bundled or downloaded models keep their own licences; see the notes above where a model is named.

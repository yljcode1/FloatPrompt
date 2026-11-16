// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FaceBeauty",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        // On-device, license-clean face beautification: landmark-driven
        // geometric warps (enlarge eyes, slim face) + masked colour touch-ups
        // (whiten teeth, brighten eyes). Vision for tracking, Core Image for
        // the effect — one builder for preview AND export.
        .library(name: "FaceBeauty", targets: ["FaceBeauty"]),
    ],
    targets: [
        .target(
            name: "FaceBeauty",
            // The .metal source is kept for reference but pre-compiled to the
            // bundled .metallib (CoreImage kernels need -fcikernel, which SPM's
            // default Metal build doesn't pass) — so exclude it from the build.
            exclude: ["Resources/FaceBeautyWarp.ci.metal"],
            resources: [.copy("Resources/FaceBeautyWarp.metallib")]
        ),
        .testTarget(name: "FaceBeautyTests", dependencies: ["FaceBeauty"]),
    ]
)

// Swift 7's import rule, today: a file must import every module whose members
// it uses, rather than leaning on another file's imports.
for target in package.targets where target.type != .system && target.type != .binary && target.type != .plugin {
    target.swiftSettings = (target.swiftSettings ?? []) + [.enableUpcomingFeature("MemberImportVisibility")]
}

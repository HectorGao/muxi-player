// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Keep development convenient without requiring a second copy of mpv. The app
// packager copies this runtime's dependency closure into Contents/Frameworks.
let configuredMPVDirectory = ProcessInfo.processInfo.environment["MUXI_MPV_LIB_DIR"]
let mpvCandidates = configuredMPVDirectory.map { [$0] } ?? [
    "/Applications/IINA.app/Contents/Frameworks",
    "/opt/homebrew/lib",
    "/usr/local/lib"
]
let mpvRuntime = mpvCandidates.lazy.compactMap { directory -> (String, String)? in
    for name in ["libmpv.2.dylib", "libmpv.dylib"] {
        if FileManager.default.fileExists(atPath: directory + "/" + name) {
            return (directory, name)
        }
    }
    return nil
}.first
guard let (mpvDirectory, mpvFilename) = mpvRuntime else {
    fatalError("libmpv is required. Install IINA or mpv, or set MUXI_MPV_LIB_DIR to the directory containing libmpv.2.dylib. See docs/mpv-runtime.md.")
}
let mpvLinkName = String(mpvFilename.dropFirst(3).dropLast(6))

let package = Package(
    name: "MuxiPlayer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MuxiPlayer", targets: ["MuxiPlayer"])],
    targets: [
        .target(name: "MuxiCore"),
        .target(name: "CMPV", publicHeadersPath: "include"),
        .executableTarget(
            name: "MuxiPlayer",
            dependencies: ["MuxiCore", "CMPV"],
            linkerSettings: [
                .linkedLibrary(mpvLinkName),
                .linkedFramework("OpenGL"),
                .unsafeFlags([
                    "-L", mpvDirectory,
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", mpvDirectory
                ])
            ]
        ),
        .testTarget(name: "MuxiCoreTests", dependencies: ["MuxiCore"])
    ],
    swiftLanguageModes: [.v5]
)

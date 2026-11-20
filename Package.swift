// swift-tools-version: 5.9
import Foundation
import PackageDescription

// reproo iOS SDK.
// Presents the hosted reporting widget in a WKWebView and delivers device context and an
// optional screenshot through the same postMessage bridge the Web SDK uses (protocol v1).
// Crash capture: the async-signal-safe handlers live in a small C target (SwiftPM cannot mix
// C and Swift in one target); the Swift target persists the black box and sends crashes.
//
// The test target is declared only where its folder is: a copy of the package without Tests/ (the
// package folder customers are sent, a vendored copy) loads as it is.
let hasTests = FileManager.default.fileExists(atPath: Context.packageDirectory + "/Tests/ReprooTests")

let package = Package(
    name: "Reproo",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "Reproo", targets: ["Reproo"]),
    ],
    targets: [
        .target(name: "ReprooCrash"),
        // The privacy manifest (required-reason APIs, collected data): Xcode merges it into the app's report.
        .target(name: "Reproo", dependencies: ["ReprooCrash"], resources: [.copy("PrivacyInfo.xcprivacy")]),
    ] + (hasTests ? [.testTarget(name: "ReprooTests", dependencies: ["Reproo", "ReprooCrash"])] : [])
)

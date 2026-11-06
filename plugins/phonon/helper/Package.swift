// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
// The Phonon voice helper: Gradium's Phonon 31m (Apache 2.0) made on the Mac, on the Kokoro helper's pipes, so
// TurnOver's natural-voice path speaks with either. Its own program, as Kokoro's is. FluidAudio 0.18.2 (Apache 2.0),
// Core ML, no Python, no GPL parts.
import PackageDescription
let package = Package(
    name: "phonon-helper",
    platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "e396cf780c4abf8e395087467c0585d3b0d17f68")],
    targets: [.executableTarget(name: "phonon-helper", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")])]
)

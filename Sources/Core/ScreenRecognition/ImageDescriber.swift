// SPDX-License-Identifier: GPL-3.0-or-later
// What a picture shows, said on request (VoiceOver's VO Shift L; a tester, AppleVis, 9 Oct 2026). On macOS 27 the
// Mac's own on-device language model looks at the picture; before that, Apple's Vision says what it recognises in it
// (a few labels, "possibly") and any text it can read. Nothing leaves the Mac either way.
import Foundation
import AppKit
import ApplicationServices
import Vision
import ScreenCaptureKit
import ImageIO
#if canImport(FoundationModels)
import FoundationModels
#endif

public enum ImageDescriber {
    private static var busy = false

    /// The picture under TurnOver's cursor: the browse-mode reading position on a page, else the navigator object,
    /// else the focus.
    public static func describeCurrent() {
        guard !busy else { Speech.speakMessage(String(localized: "still describing", comment: "Spoken message")); return }
        var element: AXUIElement?
        if let doc = API.focusTreeInterceptor, !doc.passThrough { element = doc.elementAtPosition() }
        element = element ?? ObjectNavigator.shared.element ?? API.focusObject?.element
        // Not on a picture: the window's text from the screen instead, as the menu's screen recognition gives
        // (VO-Shift-L is VoiceOver's Describe an image; Oliver, 23 Oct 2026, issue 94: a direct key for recognition
        // in the VoiceOver style, without the TurnOver layer).
        guard let element, element.role == "AXImage" else {
            Log.io("describe: not on a picture; recognising the screen")
            ScreenRecognition.shared.recognize()
            return
        }
        guard let frame = TurnOverObject.frame(element), frame.width >= 8, frame.height >= 8 else { Speech.speakMessage(String(localized: "nothing to describe here", comment: "Spoken message")); return }
        let pid = element.pid
        let windowFrame = element.element(kAXWindowAttribute).flatMap { TurnOverObject.frame($0) }
        busy = true
        Speech.speakMessage(String(localized: "describing", comment: "Spoken message"))
        Task { @MainActor in
            defer { busy = false }
            do {
                let image = try await captureElement(pid: pid, frame: frame, window: windowFrame)
                // For checking the crop: `defaults write com.turnover.reader imageDescribeSaveCapture -bool true`.
                if Edition.devDefault("imageDescribeSaveCapture"), let dest = CGImageDestinationCreateWithURL(AppPaths.file("logs/last-description.png") as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, image, nil); CGImageDestinationFinalize(dest)
                    Log.io("image description: capture \(image.width)x\(image.height) saved; element frame \(frame)")
                }
                let text = await describe(image)
                Log.io("image description: \(text.count) characters")
                Speech.speakMessage(text.isEmpty ? String(localized: "no description", comment: "A picture could not be described") : text)
            } catch {
                Log.warning("image description: capture failed: \(error.localizedDescription)")
                Speech.speakMessage(String(localized: "the picture could not be captured. TurnOver needs Screen Recording, in System Settings, Privacy and Security", comment: "Spoken message"))
            }
        }
    }

    /// The model's description when the Mac has one that sees; Vision's labels and text otherwise.
    nonisolated public static func describe(_ image: CGImage) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, *) {
            let model = SystemLanguageModel.default
            if case .available = model.availability, model.capabilities.contains(.vision) {
                do {
                    // The text in the picture comes from Vision's reader, not the model: asked to quote text, the model
                    // invented some for a photo of a rose (10 Oct 2026).
                    let session = LanguageModelSession(instructions: "You describe pictures for a blind person using a screen reader. One or two plain sentences about what the picture shows. Do not mention or quote any text in it. Do not guess who people are.")
                    let r = try await session.respond(to: Prompt {
                        "Describe this picture."
                        Attachment(image)
                    })
                    let t = r.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty {
                        let words = readText(image)
                        return words.isEmpty ? t : t + " " + String(localized: "Text: \(words)", comment: "A picture's description: the text in it")
                    }
                } catch {
                    Log.warning("image description: the language model failed: \(error.localizedDescription); Vision instead")
                }
            }
        }
        #endif
        return visionDescription(image)
    }

    /// Vision's guesses (the top few labels it is reasonably sure of) and the text it can read.
    nonisolated public static func visionDescription(_ image: CGImage) -> String {
        let classify = VNClassifyImageRequest()
        let text = VNRecognizeTextRequest(); text.recognitionLevel = .accurate; text.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([classify, text])
        let labels = (classify.results ?? []).filter { $0.confidence > 0.3 }.prefix(4)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        let words = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        return join(labels: Array(labels), words: words)
    }

    /// The text Vision can read in the picture, up to 400 characters.
    nonisolated static func readText(_ image: CGImage) -> String {
        let text = VNRecognizeTextRequest(); text.recognitionLevel = .accurate; text.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([text])
        return String((text.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").prefix(400))
    }

    nonisolated private static func join(labels: [String], words: String) -> String {
        var parts: [String] = []
        if !labels.isEmpty { parts.append(String(localized: "Possibly: \(labels.joined(separator: ", "))", comment: "A picture's description: what it may show (in English)")) }
        if !words.isEmpty { parts.append(String(localized: "Text: \(String(words.prefix(400)))", comment: "A picture's description: the text in it")) }
        return parts.joined(separator: ". ")
    }

    /// The element's own pixels: its window alone (whatever lies on top of it is not in the picture), cropped to
    /// the element. A capture of the screen region described a permission alert sitting over TextEdit instead of
    /// the picture in it (10 Oct 2026).
    static func captureElement(pid: pid_t, frame: CGRect, window: CGRect?) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        let windows = content.windows.filter { $0.owningApplication?.processID == pid && $0.isOnScreen && $0.windowLayer == 0 && $0.frame.contains(centre) }
        // The element's own window, by its frame: with several of the app's windows stacked over the same place, the
        // smallest one holding the point was another document's, behind (TextEdit, 10 Oct 2026).
        func gap(_ r: CGRect) -> CGFloat { guard let window else { return r.width * r.height }; return abs(r.minX - window.minX) + abs(r.minY - window.minY) + abs(r.width - window.width) + abs(r.height - window.height) }
        guard let w = windows.min(by: { gap($0.frame) < gap($1.frame) }) else {
            return try await ScreenRecognition.capture(ScreenRecognition.Target(pid: pid, frame: frame, title: ""))
        }
        let scale = NSScreen.screens.first { $0.frame.width >= w.frame.maxX - 1 }?.backingScaleFactor ?? 2
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        config.width = Int(w.frame.width * scale); config.height = Int(w.frame.height * scale)
        let whole = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: config)
        let local = frame.intersection(w.frame).offsetBy(dx: -w.frame.minX, dy: -w.frame.minY)
        let sx = CGFloat(whole.width) / w.frame.width, sy = CGFloat(whole.height) / w.frame.height
        let crop = CGRect(x: local.minX * sx, y: local.minY * sy, width: local.width * sx, height: local.height * sy).integral
        return whole.cropping(to: crop) ?? whole
    }
}

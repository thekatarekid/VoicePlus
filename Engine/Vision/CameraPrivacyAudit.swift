import Foundation

// V5 LR1 / LR5 — the source-level proof that camera frames are never persisted or sent anywhere.
//
// Same shape as `AmbientInjectionAudit` (R8.1): a behaviour test proves "this run stored nothing";
// this audit proves "no code on the camera path *can* store or send a frame". It reads the checkout
// and rejects, in every camera-path file:
//  * an API that writes pixels or media to disk (movie / photo outputs, asset writers, image
//    destinations, `write(to:)`, `createFile`), or that encodes an image (`jpegData`, `pngData`);
//  * a network API (`URLSession`, `URLRequest`);
//  * a *stored property* holding a pixel buffer / sample buffer / image buffer (`var x: CVPixelBuffer`,
//    `[CVPixelBuffer]`) — a frame may only be borrowed for the length of the capture callback.
// It returns nil (not an empty list) when it cannot read the sources, so a test `#require`s it.

public enum CameraPrivacyAudit {
    public struct Violation: Equatable, Sendable, CustomStringConvertible {
        public var file: String
        public var line: Int
        public var symbol: String
        public var description: String { "\(file):\(line): “\(symbol)”" }
    }

    /// Every file on the camera path, relative to the package root. Directories are walked.
    public static let cameraPaths = ["Engine/Vision", "App/Services/CameraService.swift"]

    public static let forbiddenSymbols = [
        "AVCaptureMovieFileOutput", "AVCapturePhotoOutput", "AVAssetWriter", "CGImageDestination",
        "write(to:", "createFile(", "jpegData", "pngData", "tiffRepresentation", "representation(using:",
        "URLSession", "URLRequest", "NSPasteboard",
    ]

    /// `var|let name: [?CVPixelBuffer…` at type scope or anywhere — frames are never held.
    static let storedBufferPattern = try! NSRegularExpression(
        pattern: #"\b(var|let)\s+\w+\s*:\s*\[?\s*(CVPixelBuffer|CMSampleBuffer|CVImageBuffer|CGImage|CIImage)\b"#)

    public static func packageRoot(file: String = #filePath) -> URL? {
        var url = URL(fileURLWithPath: file)
        for _ in 0..<3 { url.deleteLastPathComponent() }   // Engine/Vision/<this file> → root
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) ? url : nil
    }

    /// Swift files audited (excluding this file, which has to name what it forbids).
    public static func auditedFiles(root: URL) -> [URL] {
        var out: [URL] = []
        for path in cameraPaths {
            let url = root.appendingPathComponent(path)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                out += items.filter { $0.pathExtension == "swift" && $0.lastPathComponent != "CameraPrivacyAudit.swift" }
            } else {
                out.append(url)
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    public static func audit(root: URL) -> [Violation]? {
        let files = auditedFiles(root: root)
        guard !files.isEmpty else { return nil }
        var violations: [Violation] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let rel = String(file.path.dropFirst(root.path.count + 1))
            for (i, raw) in text.components(separatedBy: "\n").enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") { continue }
                for symbol in forbiddenSymbols where line.contains(symbol) {
                    violations.append(Violation(file: rel, line: i + 1, symbol: symbol))
                }
                let range = NSRange(line.startIndex..., in: line)
                if let m = storedBufferPattern.firstMatch(in: line, range: range), let r = Range(m.range, in: line) {
                    violations.append(Violation(file: rel, line: i + 1, symbol: String(line[r])))
                }
            }
        }
        return violations
    }
}

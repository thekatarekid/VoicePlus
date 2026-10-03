import Foundation
import Shared

// MARK: - H16 · model downloads with progress
//
// Downloads happen only on the user's click (onboarding, the one notch offer, Settings). Models are
// never bundled in the DMG. Tests inject a `ModelDownloading` mock and never touch the network.

public protocol ModelDownloading: Sendable {
    /// Fetch `model`, verify its SHA-256 and move it into place under `root`. Reports progress 0…1.
    func download(_ model: LocalLLMModel, root: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

/// URLSession with a delegate (progress callbacks), then the catalogue's SHA-verified install.
public struct URLSessionModelDownloader: ModelDownloading {
    public init() {}

    public func download(_ model: LocalLLMModel, root: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = ProgressDelegate(expected: model.bytes, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let temp: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                delegate.continuation = cont
                session.downloadTask(with: model.downloadURL).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        return try LocalLLMDownloader(root: root).installVerified(temp, as: model)
    }

    final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let expected: Int64
        let progress: @Sendable (Double) -> Void
        var continuation: CheckedContinuation<URL, Error>?
        private let lock = NSLock()

        init(expected: Int64, progress: @escaping @Sendable (Double) -> Void) {
            self.expected = expected
            self.progress = progress
        }

        private func finish(_ r: Result<URL, Error>) {
            let c: CheckedContinuation<URL, Error>? = lock.withLock { let c = continuation; continuation = nil; return c }
            c?.resume(with: r)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
            progress(min(1, Double(totalBytesWritten) / Double(max(1, total))))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                finish(.failure(LocalLLMDownloadError.transport("HTTP \(http.statusCode)"))); return
            }
            // The system deletes `location` when this returns: move it somewhere we own first.
            let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf.part")
            do {
                try FileManager.default.moveItem(at: location, to: keep)
                finish(.success(keep))
            } catch {
                finish(.failure(LocalLLMDownloadError.transport("\(error)")))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finish(.failure(LocalLLMDownloadError.transport("\(error)"))) }
        }
    }
}

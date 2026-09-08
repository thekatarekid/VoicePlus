import Darwin
import Foundation
import Shared

/// A cross-process advisory lock over the models root, held for the length of one maintenance pass.
///
/// `ModelManager.init` reconciles the on-disk layout and collects parked directories before anything
/// can ask where a model is. Both of those move and delete 468 MB trees, and neither is safe to run
/// twice at once: two VoicePlus processes starting together (a running copy plus a freshly launched
/// build, `open -n`, a relaunch racing the old instance's teardown) would interleave a park, a
/// rename and a delete over the same two paths, and the losing process's restore would land on a
/// path the winner had already taken.
///
/// `flock(2)` is the right size of tool here: it is per-open-file-description, so the kernel drops it
/// when the process exits *however* it exits — a crash mid-migration cannot leave a stale lock the
/// way a lockfile-with-a-PID-in-it can.
///
/// The wait is bounded and then abandoned rather than infinite. A hung holder must not turn into an
/// app that never finishes launching; proceeding without the lock is the same race we had before
/// this existed, which is survivable, whereas hanging is not.
enum ModelRootLock {
    static let fileName = ".voiceplus-models.lock"
    static let defaultWait: TimeInterval = 10

    /// Run `body` with the lock held, or — after `waitingUpTo` seconds of a holder that will not let
    /// go — run it anyway and say so in the log.
    @discardableResult
    static func withLock<T>(root: URL, waitingUpTo: TimeInterval = defaultWait,
                            fileManager: FileManager = .default,
                            _ body: () -> T) -> T {
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(fileName).path
        let descriptor = path.withCString { open($0, O_CREAT | O_RDWR | O_CLOEXEC, 0o644) }
        guard descriptor >= 0 else {
            Log.engine.error("model root lock: could not open \(fileName) (errno \(errno)); running unlocked")
            return body()
        }
        defer { close(descriptor) }   // releases the flock too, whichever way we leave

        let deadline = Date().addingTimeInterval(waitingUpTo)
        var held = false
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { held = true; break }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if !held {
            Log.engine.error("model root lock: another process has held it for \(Int(waitingUpTo))s; running model maintenance unlocked")
        }
        defer { if held { flock(descriptor, LOCK_UN) } }
        return body()
    }
}

import Actions
import AppKit
import Testing
@testable import VoicePlusApp

/// 1.6.6 P1 — "the app crashes when I press the dictation key."
///
/// `OverlayWindow` declares its own designated initializer and has stored properties with no
/// defaults, so it inherits none of `NSWindow`'s initializers, and Swift emits an @objc **trap
/// stub** for the designated one it does not override. The old code called the five-argument
/// `super.init(contentRect:styleMask:backing:defer:screen:)`, an ObjC convenience initializer that
/// AppKit re-dispatches through `self` — straight into that stub. Every
/// `InkOverlayController.show()`, i.e. every press of the dictation key, died with
/// "Fatal error: Use of unimplemented initializer" and EXC_BREAKPOINT. Unconditionally, on every
/// Mac, from the first keypress.
///
/// It was never caught because nothing in the whole test suite ever *constructed* a window. This
/// does — that is the entire point. There is no assertion to make beyond "it returns": a class whose
/// initializer is a trap cannot be tested any other way, and this test would have failed at the
/// commit that introduced it.
@Suite("Overlay windows can actually be constructed (P1)")
@MainActor
struct OverlayWindowInitTests {
    private static let display = DisplayFrame(id: 1, frame: CGRect(x: 0, y: 0, width: 1800, height: 1169))

    @Test func theDesignatedInitializerDoesNotTrap() {
        let window = OverlayWindow(display: Self.display, screen: nil)
        #expect(window.display == Self.display)
        #expect(window.frame == Self.display.frame, "the window must still land on its display")
        #expect(window.contentView === window.inkView)
        #expect(!window.canBecomeKey && !window.canBecomeMain)
        window.orderOut(nil)
    }

    /// The initializer AppKit re-dispatches to. Reaching it used to be fatal; it now has a real
    /// implementation, so nothing macOS does can resurrect the trap.
    @Test func theInitializerAppKitReDispatchesToIsImplemented() {
        let rect = CGRect(x: 10, y: 20, width: 400, height: 300)
        let window = OverlayWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        #expect(window.frame.size == rect.size)
        #expect(window.contentView === window.inkView)
        window.orderOut(nil)
    }

    /// A second display, an off-origin frame, and a real `NSScreen` where one exists — the shapes
    /// `InkOverlayController.rebuildWindows()` actually produces.
    @Test func everyDisplayShapeConstructs() {
        let frames = [
            CGRect(x: 0, y: 0, width: 1800, height: 1169),
            CGRect(x: 1800, y: 89, width: 1920, height: 1080),
            CGRect(x: -1440, y: -200, width: 1440, height: 900),
        ]
        for (i, frame) in frames.enumerated() {
            let d = DisplayFrame(id: UInt32(i + 1), frame: frame)
            let window = OverlayWindow(display: d, screen: NSScreen.screens.first { $0.frame == frame })
            #expect(window.frame == frame)
            window.orderOut(nil)
        }
    }
}

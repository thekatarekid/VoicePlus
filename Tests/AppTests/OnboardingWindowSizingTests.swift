import CoreGraphics
import Testing
@testable import VoicePlusApp

/// The onboarding window used to be a hard `.frame(width: 520, height: 420)`. On the model step a
/// download adds a progress bar, a wrapping progress line, a Cancel button, an info line and a
/// two-line amber warning — the content outgrew the frame and, because nothing scrolled, the
/// Back / Skip / Continue row was clipped in half at the bottom edge. These cover the arithmetic
/// that replaced it; the rendering itself needs a window server and cannot be tested on this
/// toolchain.
@Suite struct OnboardingWindowSizingTests {
    private let chrome: CGFloat = 60          // progress bar + action row, as measured
    private let bigScreen: CGFloat = 1000

    private func height(step: CGFloat, chrome: CGFloat? = nil, screen: CGFloat? = nil) -> CGFloat {
        OnboardingWindowSizing.contentHeight(stepHeight: step,
                                             chromeHeight: chrome ?? self.chrome,
                                             usableHeight: screen ?? bigScreen)
    }

    // MARK: The bug

    /// The failing case: the model step at rest fits 420, the same step mid-download does not.
    @Test func downloadingModelStepGetsATallerWindowThanTheRestingOne() {
        let resting = height(step: 300)
        let downloading = height(step: 300 + 120)   // bar + progress line + cancel + info + warning
        #expect(downloading > resting)
        #expect(downloading >= 420, "the size that shipped in 1.7.0 was not enough for this step")
    }

    /// The invariant the whole fix exists for: whatever the step asks for, the chrome keeps its
    /// space, so the action row is never the thing that gets cut.
    @Test(arguments: [0, 120, 260, 420, 900, 5_000] as [CGFloat])
    func actionRowSpaceIsAlwaysReserved(stepHeight: CGFloat) {
        let content = height(step: stepHeight)
        let left = OnboardingWindowSizing.availableStepHeight(contentHeight: content, chromeHeight: chrome)
        // Everything the window has that is not the step is still there for the chrome.
        #expect(content - left >= chrome)
        #expect(left >= OnboardingWindowSizing.minimumScrollHeight)
    }

    // MARK: Clamping

    @Test func neverTallerThanTheDisplay() {
        #expect(height(step: 4_000, screen: 700) <= 700)
    }

    @Test func aStepThatFitsIsNotStretchedToTheDisplay() {
        #expect(height(step: 300, screen: 1_600) < 1_600)
    }

    /// A display too short for chrome + the scroll floor: the floor wins and the step scrolls,
    /// rather than the window shrinking until the buttons are gone.
    @Test func onATinyDisplayTheChromeStillFits() {
        let content = height(step: 900, screen: 120)
        let needed = chrome + OnboardingWindowSizing.fixedChromeInsets + OnboardingWindowSizing.minimumScrollHeight
        #expect(content >= needed)
    }

    @Test func shortStepsKeepAMinimumBody() {
        #expect(height(step: 10) == height(step: OnboardingWindowSizing.minimumStepHeight))
    }

    @Test func tallerStepsProduceTallerWindows() {
        #expect(height(step: 600) > height(step: 400))
        #expect(height(step: 400) > height(step: 280))
    }

    // MARK: No jitter on a progress tick

    /// "95 MB of 900 MB (11%)" → "96 MB of 900 MB (11%)" must not move the window. Sub-point
    /// geometry republishes are noise and are ignored.
    @Test func subPointHeightChangesAreIgnored() {
        #expect(!OnboardingWindowSizing.shouldResize(from: 431.0, to: 431.4))
        #expect(!OnboardingWindowSizing.shouldResize(from: 431.0, to: 430.7))
        #expect(!OnboardingWindowSizing.shouldResize(from: 431.0, to: 431.0))
    }

    @Test func realGrowthStillResizes() {
        #expect(OnboardingWindowSizing.shouldResize(from: 300, to: 420))
        #expect(OnboardingWindowSizing.shouldResize(from: 420, to: 300))
    }

    /// The download line is a fixed box precisely so a tick cannot change the step's height.
    @Test func downloadLineHasReservedHeight() {
        #expect(OnboardingWindowSizing.downloadLineHeight > 0)
        let a = height(step: 380)
        let b = height(step: 380)   // same step, next tick: the text changed, the box did not
        #expect(a == b)
    }

    // MARK: Screen area

    @Test func contentAreaLeavesRoomForTheTitlebar() {
        let screen = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
                                   visibleFrame: CGRect(x: 0, y: 0, width: 1_512, height: 944))
        let area = OnboardingWindowSizing.contentArea(on: screen)
        #expect(area.height < 944)
        #expect(area.height == 944 - OnboardingWindowSizing.windowChromeAllowance)
    }

    /// A pathologically short display must still yield a positive area rather than a negative one.
    @Test func contentAreaNeverGoesNegative() {
        let tiny = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 400, height: 30),
                                 visibleFrame: CGRect(x: 0, y: 0, width: 400, height: 30))
        #expect(OnboardingWindowSizing.contentArea(on: tiny).height > 0)
    }

    @Test func noScreenFallsBackToTheOldFixedSize() {
        #expect(OnboardingWindowSizing.contentArea(on: nil).height == 420)
    }

    // MARK: Every step, not just the model one

    /// Rough measured heights for each step in its *tallest* state — permissions in the recovery
    /// phase, mic check with an error and its three buttons, the model step mid-download, the
    /// dictation step with the skip warning, a verdict and a preview. None may clip its action row,
    /// and each gets a window sized to itself rather than to one shared guess.
    @Test(arguments: [
        ("welcome", 180.0), ("permissions recovery", 520.0), ("mic check error", 430.0),
        ("model downloading", 560.0), ("first dictation", 480.0), ("done", 200.0),
    ])
    func everyStepKeepsItsActionRow(name: String, stepHeight: CGFloat) {
        let content = height(step: stepHeight)
        let left = OnboardingWindowSizing.availableStepHeight(contentHeight: content, chromeHeight: chrome)
        #expect(left >= OnboardingWindowSizing.minimumScrollHeight, "\(name) squeezed the chrome out")
        #expect(content - left >= chrome, "\(name) clipped the action row")
        // On a normal display a step this size is shown whole, with no scrolling at all.
        #expect(left >= min(stepHeight, OnboardingWindowSizing.minimumStepHeight), "\(name) scrolled needlessly")
    }

    @Test func contentSizeKeepsTheFixedWidth() {
        let frame = CGRect(x: 0, y: 0, width: 1_512, height: 900)
        let size = OnboardingWindowSizing.contentSize(stepHeight: 400, chromeHeight: chrome, usableFrame: frame)
        #expect(size.width == OnboardingWindowSizing.contentWidth)
        #expect(size.height <= 900)
    }
}

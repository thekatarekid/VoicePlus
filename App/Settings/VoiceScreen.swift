import SwiftUI

// S7a entry point — owned by S7e from here on (build doc §3: `App/Settings/Voice*.swift`).
//
// The shell builds `VoiceScreen(context:)` and nothing else for this section, so S7e replaces this
// body with the design's Voice (design §8.4) drawn in `SectionPage` with `App/UI/Components/`, with
// the benchmarks in a disclosure whose open state is
// `context.navigation.isExpanded(.benchmarks)` (the old Benchmark tab's deep link opens it), without
// touching the shell. Until then it hosts the R7 Voice pane unchanged.
struct VoiceScreen: SectionScreen {
    static let section: MainWindowSection = .voice

    let context: SectionContext

    init(context: SectionContext) { self.context = context }

    var body: some View {
        VoiceSectionView(model: context.window.voice)
    }
}

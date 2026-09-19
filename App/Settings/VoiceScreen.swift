import SwiftUI

// S7e — Voice (design §8.4, §9), the section's `SectionScreen` entry point.
//
// One page, one base rendering (`VoiceSectionViewModel.page`): "Looking for microphones…" until the
// inputs are enumerated, then the content, with a scoped banner when the microphone permission is
// off (P01) or the chosen microphone vanished (A02). The groups inside keep their own states —
// "No microphones found" and "No voice enrolled" are two different things and never blank the page.
//
// The microphone test never outlives the page: switching section or closing the window closes the
// microphone (design §8.4 "Stop testing releases the microphone"). The benchmarks disclosure's open
// state is `context.navigation.isExpanded(.benchmarks)`, so the old Benchmark tab's deep link opens it.
struct VoiceScreen: SectionScreen {
    static let section: MainWindowSection = .voice

    let context: SectionContext
    @ObservedObject private var model: VoiceSectionViewModel
    @ObservedObject private var window: MainWindowViewModel

    init(context: SectionContext) {
        self.context = context
        _model = ObservedObject(wrappedValue: context.window.voice)
        _window = ObservedObject(wrappedValue: context.window)
    }

    var body: some View {
        SectionPage(context.page, state: model.page, banner: model.pageBanner,
                    onBannerAction: { model.performBannerAction() }, hotkey: context.hotkey) {
            VoiceSectionView(model: model, navigation: context.navigation, hotkey: context.hotkey)
        }
        // Enumerating is what ends "Looking for microphones…"; it runs outside the content, which the
        // loading rendering does not draw.
        .onAppear { model.refreshDevices() }
        .onDisappear { model.leave() }
        .onChange(of: window.selection) { _, selection in
            if selection == .voice {
                model.refresh()
                model.refreshDevices()
            } else {
                model.leave()
            }
        }
    }
}

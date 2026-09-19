import SwiftUI

/// S7a — the design's segmented switch (prototype `.segmented`: Dictionary / Apps, Final text /
/// Original transcript, Notes / Transcript / Ask, and Settings' subnav). It is the system segmented
/// picker — `DESIGN.md` §12.4 allows no custom control where a system control exists — with the
/// label kept for VoiceOver and hidden on screen.
struct SegmentedControl<Option: Hashable>: View {
    var label: String
    var options: [Option]
    @Binding var selection: Option
    var title: (Option) -> String
    var identifier: String?

    init(_ label: String, options: [Option], selection: Binding<Option>, identifier: String? = nil,
         title: @escaping (Option) -> String) {
        self.label = label
        self.options = options
        self._selection = selection
        self.identifier = identifier
        self.title = title
    }

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(options, id: \.self) { option in
                Text(title(option)).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier ?? "segmented")
    }
}

extension SegmentedControl where Option: CaseIterable, Option.AllCases == [Option] {
    /// Every case, in declaration order.
    init(_ label: String, selection: Binding<Option>, identifier: String? = nil, title: @escaping (Option) -> String) {
        self.init(label, options: Option.allCases, selection: selection, identifier: identifier, title: title)
    }
}

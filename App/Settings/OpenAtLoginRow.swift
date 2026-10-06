import AppKit
import SwiftUI

/// Settings › General "Open at login" row (`LoginItemService`). Shows the real SMAppService status:
/// on / off / needs approval in System Settings (with a button to that pane) / unavailable for this
/// copy (DMG, translocated, not in Applications) with the reason.
struct OpenAtLoginRow: View {
    @ObservedObject var service: LoginItemService = .shared
    @State private var failure: String?

    var body: some View {
        RowView(LoginItemCopy.title, detail: failure ?? LoginItemCopy.detail(service.state)) {
            HStack(spacing: Tokens.Spacing.s) {
                if service.state == .requiresApproval {
                    Button(LoginItemCopy.openLoginItems) { service.openLoginItemsSettings() }
                        .accessibilityIdentifier("settings.launchAtLogin.openLoginItems")
                }
                Toggle(LoginItemCopy.title, isOn: Binding(
                    get: { service.isOn },
                    set: { on in
                        do {
                            try service.setEnabled(on)
                            failure = nil
                        } catch let error as LoginItemNotSaved {
                            failure = "Couldn’t change this: \(error.reason)"
                        } catch {
                            failure = "Couldn’t change this: \(error.localizedDescription)"
                        }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!service.isAvailable)
                .accessibilityIdentifier("settings.launchAtLogin")
            }
        }
        .onAppear { service.refresh() }
        // Coming back from System Settings › Login Items: show what the user changed there.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            service.refresh()
        }
    }
}

/// Onboarding's last step: "Open VoicePlus at login", checked by default (the default-ON choice).
struct OnboardingOpenAtLoginCheckbox: View {
    @ObservedObject var service: LoginItemService = .shared

    var body: some View {
        if service.isAvailable {
            Toggle(LoginItemCopy.onboardingCheckbox, isOn: Binding(
                get: { service.isOn },
                set: { on in try? service.setEnabled(on) }
            ))
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("onboarding.openAtLogin")
        }
    }
}

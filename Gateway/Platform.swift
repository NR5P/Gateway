import SwiftUI

/// What a text field holds, so iOS can pick a keyboard; macOS ignores it.
enum InputKind {
    case callsign, email, url, number, plain
}

extension View {
    /// Autocorrect off everywhere; on iOS also the right keyboard and capitalisation.
    @ViewBuilder
    func input(_ kind: InputKind) -> some View {
        #if os(iOS)
        switch kind {
        case .callsign:
            self.textInputAutocapitalization(.characters).autocorrectionDisabled()
        case .email:
            self.textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
        case .url:
            self.textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
        case .number:
            self.keyboardType(.numberPad)
        case .plain:
            self.textInputAutocapitalization(.never).autocorrectionDisabled()
        }
        #else
        self.autocorrectionDisabled()
        #endif
    }

    @ViewBuilder
    func inlineTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Grouped forms on macOS look like the iOS ones.
    @ViewBuilder
    func groupedForm() -> some View {
        #if os(macOS)
        self.formStyle(.grouped)
        #else
        self
        #endif
    }
}

extension ToolbarItemPlacement {
    /// The bottom bar on iOS; the window toolbar on macOS.
    static var messageActions: ToolbarItemPlacement {
        #if os(iOS)
        .bottomBar
        #else
        .automatic
        #endif
    }
}

import SwiftUI

private struct WorkspaceOpenFolderActionKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

extension FocusedValues {
    var workspaceOpenFolder: (@MainActor () -> Void)? {
        get { self[WorkspaceOpenFolderActionKey.self] }
        set { self[WorkspaceOpenFolderActionKey.self] = newValue }
    }
}

public struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspaceOpenFolder) private var openFolder

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(L10n.text("Open Folder…")) { openFolder?() }
                .keyboardShortcut("o", modifiers: [.command])
                .disabled(openFolder == nil)
        }
    }
}

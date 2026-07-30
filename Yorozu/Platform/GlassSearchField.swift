import AppKit
import SwiftUI

struct GlassSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    let placeholder: String
    let accessibilityLabel: String
    let leadingInset: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSView {
        let searchField = NSSearchField()
        searchField.controlSize = .large
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .preferredFont(forTextStyle: .title2)
        searchField.placeholderString = placeholder
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = context.coordinator
        searchField.identifier = NSUserInterfaceItemIdentifier("launcher.search")
        searchField.setAccessibilityLabel(accessibilityLabel)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        if let cell = searchField.cell as? NSSearchFieldCell {
            // An unbordered NSSearchField on macOS 26 can place its search glyph
            // over the editor text. The palette already communicates search
            // through its placeholder, so keep the standard clear button only.
            cell.searchButtonCell = nil
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(searchField)
        let leadingConstraint = searchField.leadingAnchor.constraint(
            equalTo: container.leadingAnchor,
            constant: leadingInset
        )
        NSLayoutConstraint.activate([
            leadingConstraint,
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 15),
            searchField.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -15),
        ])

        context.coordinator.searchField = searchField
        context.coordinator.leadingConstraint = leadingConstraint
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let searchField = context.coordinator.searchField else { return }
        if searchField.stringValue != text {
            searchField.stringValue = text
        }
        if let editor = searchField.currentEditor(),
           (editor.delegate as AnyObject?) === searchField,
           editor.string != text {
            editor.string = text
            editor.selectedRange = NSRange(
                location: (text as NSString).length,
                length: 0
            )
        }
        searchField.placeholderString = placeholder
        searchField.setAccessibilityLabel(accessibilityLabel)
        context.coordinator.leadingConstraint?.constant = leadingInset
        guard context.coordinator.lastFocusRequest != focusRequest else { return }
        context.coordinator.lastFocusRequest = focusRequest
        DispatchQueue.main.async {
            searchField.window?.makeFirstResponder(searchField)
            guard let editor = searchField.currentEditor() else { return }
            editor.string = searchField.stringValue
            editor.selectedRange = NSRange(
                location: (searchField.stringValue as NSString).length,
                length: 0
            )
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding private var text: String
        weak var searchField: NSSearchField?
        var leadingConstraint: NSLayoutConstraint?
        var lastFocusRequest = -1

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            text = searchField.stringValue
        }
    }
}

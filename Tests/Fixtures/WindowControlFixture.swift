import AppKit

// Build this as a separate executable for the opt-in AX integration test. It
// contains no user data and never activates itself or receives injected input.
@main
struct WindowControlFixture {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1_280, height: 800)
        let size = CGSize(
            width: min(640, visibleFrame.width - 120),
            height: min(420, visibleFrame.height - 120)
        )
        let window = NSWindow(
            contentRect: CGRect(
                x: visibleFrame.minX + 40,
                y: visibleFrame.minY + 40,
                width: size.width,
                height: size.height
            ),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Yorozu Window Control Test Fixture"
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 160, height: 120)
        let field = NSTextField(frame: CGRect(x: 24, y: 24, width: 240, height: 28))
        field.placeholderString = "Isolated window-control fixture"
        window.contentView?.addSubview(field)
        window.center()
        window.orderFront(nil)

        // A failed or interrupted test must not leave its fixture running.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            application.terminate(nil)
        }
        withExtendedLifetime(window) {
            application.run()
        }
    }
}

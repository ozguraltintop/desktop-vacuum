import SwiftUI
import AppKit

@main
struct RobotSupurgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private let vm = RobotViewModel()

    private var screen: NSScreen { NSScreen.screens[0] }

    /// Boştayken: ekranın üst ortasında 100x100'lük küçük pencere
    private var idleFrame: NSRect {
        let vf = screen.visibleFrame
        return NSRect(x: screen.frame.midX - 50, y: vf.maxY - 100, width: 100, height: 100)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // Dock'ta görünmesin

        setupPanel()
        setupStatusItem()

        vm.expand = { [weak self] in
            guard let self else { return }
            self.panel.ignoresMouseEvents = true
            self.panel.setFrame(self.screen.frame, display: true)
            let menuBar = self.screen.frame.maxY - self.screen.visibleFrame.maxY
            self.vm.home = CGPoint(x: self.screen.frame.midX - self.screen.frame.minX,
                                   y: menuBar + 50)
            self.vm.canvasSize = self.screen.frame.size
        }
        vm.collapse = { [weak self] in
            guard let self else { return }
            self.panel.setFrame(self.idleFrame, display: true)
            self.panel.ignoresMouseEvents = false
        }
    }

    private func setupPanel() {
        panel = NSPanel(contentRect: idleFrame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: RobotView(vm: vm))
        panel.orderFrontRegardless()
    }

    private func setupStatusItem() {
        statusItem = NSStatusItem.systemStatusItem()
        let menu = NSMenu()
        menu.addItem(withTitle: "Masaüstünü Temizle", action: #selector(clean), keyEquivalent: "t").target = self
        menu.addItem(withTitle: "Hedef Klasörü Seç…", action: #selector(chooseFolder), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Çıkış", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
    }

    @objc private func clean() {
        Task { @MainActor in await vm.startCleaning() }
    }

    @objc private func chooseFolder() {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.canCreateDirectories = true
        open.prompt = "Bu Klasöre Taşı"
        NSApp.activate(ignoringOtherApps: true)
        if open.runModal() == .OK, let url = open.url {
            vm.customDestination = url
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

private extension NSStatusItem {
    static func systemStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Robot Süpürge")
        return item
    }
}

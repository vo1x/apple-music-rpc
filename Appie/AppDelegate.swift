import Cocoa
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {
    private var appleMusicRPC: AppleMusicDiscordRPC?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appleMusicRPC = AppleMusicDiscordRPC(discordAppId: "1393235679097393182")
        
        appleMusicRPC?.onPermissionError = { [weak self] message in
            self?.showPermissionAlert(message: message)
        }

        appleMusicRPC?.start()
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "music.quarternote.3",
                                           accessibilityDescription: "Apple Music RPC")
        
        setupStatusMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appleMusicRPC?.stop()
    }
    
    private func setupStatusMenu() {
        let menu = NSMenu()
        
        menu.addItem(NSMenuItem(title: "Reconnect Discord", action: #selector(reconnectDiscord), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Update Presence Now", action: #selector(updatePresence), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Clear Presence", action: #selector(clearPresence), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    @objc private func reconnectDiscord() {
        print("Manually reconnecting to Discord...")
        appleMusicRPC?.reconnectDiscord()
    }
    
    @objc private func updatePresence() {
        print("Manually triggering presence update...")
        appleMusicRPC?.triggerPresenceUpdate()
    }
    
    @objc private func clearPresence() {
        print("Manually clearing Discord presence...")
        appleMusicRPC?.clearDiscordPresence()
    }

    private func showPermissionAlert(message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Automation Permission Required"
            alert.informativeText = message
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Close")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

import Foundation
import Cocoa

@MainActor
class UpdateService {
    static let shared = UpdateService()
    
    var currentVersion = "1.0"
    
    func checkUpdate(explicit: Bool) {
        if explicit {
            print("🚀 UpdateService: Explicitly checking for updates...")
        } else {
            print("🚀 UpdateService: Auto-checking for updates (Background)...")
        }
        
        // Mocking an update check
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            if explicit {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Check for Updates"
                    // Corrected the informativeText to dynamically include currentVersion
                    alert.informativeText = "You are currently using the latest version (\(UpdateService.shared.currentVersion))."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            } else {
                print("🚀 UpdateService: No update found (Auto-check)")
            }
        }
    }
}

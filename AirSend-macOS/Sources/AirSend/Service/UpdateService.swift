import Foundation
import Cocoa

@MainActor
class UpdateService {
    static let shared = UpdateService()
    
    var currentVersion = "1.0"
    
    private let owner = "Avi7ii"
    private let repo = "AirSend"
    private let releaseURL = "https://github.com/Avi7ii/AirSend/releases/latest"
    private let apiURL = "https://api.github.com/repos/Avi7ii/AirSend/releases/latest"

    func checkUpdate(explicit: Bool) {
        if explicit {
            print("🚀 UpdateService: Explicitly checking for updates...")
        } else {
            print("🚀 UpdateService: Auto-checking for updates (Background)...")
        }
        
        Task {
            do {
                guard let latestVersion = try await fetchLatestVersion() else {
                    if explicit {
                        await showNoUpdateAlert()
                    }
                    return
                }
                
                print("🚀 UpdateService: Current version: \(currentVersion), Latest version: \(latestVersion)")
                
                if isNewerVersion(latestVersion, than: currentVersion) {
                    await showUpdateAlert(newVersion: latestVersion)
                } else if explicit {
                    await showNoUpdateAlert()
                }
            } catch {
                print("❌ UpdateService: Failed to check updates: \(error)")
                if explicit {
                    await showErrorAlert(error: error)
                }
            }
        }
    }

    private func fetchLatestVersion() async throws -> String? {
        var request = URLRequest(url: URL(string: apiURL)!)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("AirSend-Update-Service", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }
        
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tagName = json["tag_name"] as? String {
            // Remove 'v' prefix if exists
            return tagName.lowercased().hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        }
        
        return nil
    }

    private func isNewerVersion(_ latest: String, than current: String) -> Bool {
        let latestComponents = latest.split(separator: ".").compactMap { Int($0) }
        let currentComponents = current.split(separator: ".").compactMap { Int($0) }
        
        let count = max(latestComponents.count, currentComponents.count)
        for i in 0..<count {
            let l = i < latestComponents.count ? latestComponents[i] : 0
            let r = i < currentComponents.count ? currentComponents[i] : 0
            if l > r { return true }
            if l < r { return false }
        }
        return false
    }

    private func showUpdateAlert(newVersion: String) async {
        let alert = NSAlert()
        alert.messageText = "New Version Available"
        alert.informativeText = "A new version (\(newVersion)) is available. Would you like to download it now?"
        alert.addButton(withTitle: "Download Now")
        alert.addButton(withTitle: "Later")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: releaseURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func showNoUpdateAlert() async {
        let alert = NSAlert()
        alert.messageText = "Check for Updates"
        alert.informativeText = "You are currently using the latest version (\(currentVersion))."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showErrorAlert(error: Error) async {
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = "An error occurred while checking for updates: \(error.localizedDescription)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

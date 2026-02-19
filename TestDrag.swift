import Cocoa

let dragPboard = NSPasteboard(name: .drag)
var lastCount = dragPboard.changeCount

print("Monitoring drag pasteboard... (Ctrl+C to stop)")
print("Initial Count: \(lastCount)")

while true {
    let currentCount = dragPboard.changeCount
    if currentCount != lastCount {
        print("Drag Pasteboard Changed! Count: \(currentCount)")
        lastCount = currentCount
    }
    Thread.sleep(forTimeInterval: 0.1)
}

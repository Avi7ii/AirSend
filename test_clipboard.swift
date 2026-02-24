import Cocoa

let pasteboard = NSPasteboard.general
if let availableTypes = pasteboard.types {
    print("Available types: \(availableTypes.map { $0.rawValue })")
}

if let tiffData = pasteboard.data(forType: .tiff) {
    print("Has TIFF data: \(tiffData.count) bytes")
} else {
    print("No TIFF data")
}

if let str = pasteboard.string(forType: .string) {
    print("Has String data: \(str.count) chars")
} else {
    print("No String data")
}

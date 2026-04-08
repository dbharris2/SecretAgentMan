import Foundation

extension URL {
    var tildeAbbreviatedPath: String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

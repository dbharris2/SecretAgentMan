import Foundation

enum PerfLogger {
    static func log(_ activity: String, start: CFAbsoluteTime, details: @autoclosure () -> String = "") {
        #if DEBUG
            let suffix = details()
            if suffix.isEmpty {
                NSLog("[Perf] \(activity) took %.0fms", elapsedMilliseconds(since: start))
            } else {
                NSLog("[Perf] \(activity) \(suffix) took %.0fms", elapsedMilliseconds(since: start))
            }
        #endif
    }

    static func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000
    }
}

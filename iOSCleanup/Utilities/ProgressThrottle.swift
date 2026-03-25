import Foundation

final class ProgressThrottle: @unchecked Sendable {
    private let minInterval: Int
    private var lastReported = -1
    private let lock = NSLock()

    init(every minInterval: Int = 50) {
        self.minInterval = minInterval
    }

    func shouldReport(completed: Int) -> Bool {
        lock.withLock {
            if completed - lastReported >= minInterval {
                lastReported = completed
                return true
            }
            return false
        }
    }
}

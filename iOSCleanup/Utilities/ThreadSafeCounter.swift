import Foundation

final class ThreadSafeCounter: @unchecked Sendable {
    private var _value = 0
    private let lock = NSLock()

    var value: Int { lock.withLock { _value } }

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            _value += 1
            return _value
        }
    }

    func reset() { lock.withLock { _value = 0 } }
}

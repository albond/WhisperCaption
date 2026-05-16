import Foundation

/// Weak-reference holder used to verify a heap object was released after
/// the test stopped strongly referencing it.
///
/// Usage:
///     let probe: LeakProbe<MyClass>
///     do {
///         let obj = MyClass()
///         probe = LeakProbe(obj)
///         // exercise obj, then let scope close so the strong ref drops
///     }
///     // Yield once so any unstructured Tasks holding the object finish.
///     await Task.yield()
///     #expect(probe.isAlive == false, "MyClass leaked")
///
/// Used heavily in the memory-leak suite to assert engines, transports,
/// and pump tasks don't keep their owners alive past close()/stop().
final class LeakProbe<T: AnyObject>: @unchecked Sendable {
    weak var target: T?
    let label: String

    init(_ target: T, label: String = String(describing: T.self)) {
        self.target = target
        self.label = label
    }

    /// True while the target is still in memory.
    var isAlive: Bool { target != nil }
}

/// Convenience for tests that need to give ARC + the runloop a couple of
/// chances to drop a reference (especially for actor-isolated state and
/// unstructured `Task`s that haven't been awaited).
@inline(__always)
func drainPendingTasks(rounds: Int = 4) async {
    for _ in 0..<rounds {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000) // 1 ms
    }
}

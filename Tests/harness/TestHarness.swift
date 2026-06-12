import Foundation

/// Minimal assert harness for swiftc-compiled tests. This project builds
/// with Command Line Tools only (no Xcode → no XCTest), so tests are plain
/// Swift compiled alongside the pure-logic sources by `run-tests.sh`. Each
/// check records pass/fail; `main.swift` exits non-zero if any failed.
final class Checks {
    private(set) var failures = 0
    private(set) var passed = 0
    let suite: String
    init(_ suite: String) { self.suite = suite }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        if condition { passed += 1 }
        else { failures += 1; print("  ✗ [\(suite)] \(message())") }
    }

    func equal<T: Equatable>(_ a: T, _ b: T, _ label: String) {
        expect(a == b, "\(label): expected \(b), got \(a)")
    }
}

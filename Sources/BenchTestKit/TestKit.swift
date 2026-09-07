// Ported from Klip's Tests/TestRunner.swift (MIT, Copyright 2026 Sam Reza).
// Minimal dependency-free test framework: this Mac has only the Command Line
// Tools, so there is no XCTest. Each module has its own `<Module>Tests`
// executable that registers suites and calls `runSuites`.

import Foundation

public struct TestFailure: Error {
    public let message: String
    public let file: StaticString
    public let line: UInt

    public init(message: String, file: StaticString, line: UInt) {
        self.message = message
        self.file = file
        self.line = line
    }
}

public typealias TestCase = (String, () throws -> Void)
public typealias TestSuite = (String, [TestCase])

public func expect(_ condition: Bool, _ message: String, file: StaticString = #file, line: UInt = #line) throws {
    if !condition {
        throw TestFailure(message: message, file: file, line: line)
    }
}

public func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    if a != b {
        let detail = "\(a) != \(b)"
        let full = message.isEmpty ? detail : "\(message) (\(detail))"
        throw TestFailure(message: full, file: file, line: line)
    }
}

public func expectNil<T>(_ value: T?, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    if value != nil {
        let full = message.isEmpty ? "expected nil, got \(String(describing: value))" : message
        throw TestFailure(message: full, file: file, line: line)
    }
}

public func expectNotNil<T>(_ value: T?, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    if value == nil {
        let full = message.isEmpty ? "expected non-nil value" : message
        throw TestFailure(message: full, file: file, line: line)
    }
}

/// Creates a fresh temp directory, hands it to `body`, and removes it
/// afterwards (even if `body` throws).
public func withTempDir<R>(_ body: (URL) throws -> R) rethrows -> R {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("BenchTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try body(dir)
}

/// Runs every suite, prints PASS/FAIL per test and a summary, and returns
/// the process exit status (1 when anything failed). `filter`, when given,
/// runs only tests whose full name contains it (`BENCH_TEST_FILTER`).
public func runSuites(_ suites: [TestSuite], filter: String? = ProcessInfo.processInfo.environment["BENCH_TEST_FILTER"]) -> Int32 {
    var passed = 0
    var failed = 0

    for (suiteName, tests) in suites {
        for (testName, test) in tests {
            let fullName = "\(suiteName).\(testName)"
            if let filter, !filter.isEmpty, !fullName.contains(filter) { continue }
            do {
                try test()
                print("PASS \(fullName)")
                passed += 1
            } catch let failure as TestFailure {
                print("FAIL \(fullName): \(failure.message) (\(failure.file):\(failure.line))")
                failed += 1
            } catch {
                print("FAIL \(fullName): \(error)")
                failed += 1
            }
        }
    }

    print("\(passed) passed, \(failed) failed")
    return failed > 0 ? 1 : 0
}

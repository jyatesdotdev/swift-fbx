import Foundation

/// Tolerant structural JSON comparison per docs/DUMP_FORMAT.md.
///
/// - Numbers compare with `|a-b| <= 1e-6 + 1e-6 * max(|a|,|b|)`.
/// - A key absent on one side matches `null`, `false`, `-1`, `[]`, or `{}` on the other.
/// - Keys named `absolute_filename` are ignored.
/// - Everything else (strings, bools, array lengths, ordering) must match exactly.
enum JSONCompare {
    static let tolerance = 1e-6

    /// Returns divergence descriptions, empty when equal. Reporting caps at `maxDiffs`.
    static func diff(expected: Any, actual: Any, maxDiffs: Int = 25) -> [String] {
        var diffs: [String] = []
        compare(expected, actual, path: "$", diffs: &diffs, maxDiffs: maxDiffs)
        return diffs
    }

    private static func compare(_ lhs: Any, _ rhs: Any, path: String, diffs: inout [String], maxDiffs: Int) {
        guard diffs.count < maxDiffs else { return }

        switch (classify(lhs), classify(rhs)) {
        case let (.object(l), .object(r)):
            for key in Set(l.keys).union(r.keys).sorted() {
                guard diffs.count < maxDiffs else { return }
                if key == "absolute_filename" { continue }
                let childPath = "\(path).\(key)"
                switch (l[key], r[key]) {
                case let (lv?, rv?):
                    compare(lv, rv, path: childPath, diffs: &diffs, maxDiffs: maxDiffs)
                case let (lv?, nil):
                    if !isAbsentEquivalent(lv) { diffs.append("\(childPath): missing in actual, expected \(short(lv))") }
                case let (nil, rv?):
                    if !isAbsentEquivalent(rv) { diffs.append("\(childPath): unexpected \(short(rv))") }
                case (nil, nil):
                    break
                }
            }
        case let (.array(l), .array(r)):
            if l.count != r.count {
                diffs.append("\(path): array count \(l.count) != \(r.count)")
                return
            }
            for i in 0..<l.count {
                guard diffs.count < maxDiffs else { return }
                compare(l[i], r[i], path: "\(path)[\(i)]", diffs: &diffs, maxDiffs: maxDiffs)
            }
        case let (.number(l), .number(r)):
            if !(abs(l - r) <= tolerance + tolerance * max(abs(l), abs(r))) {
                diffs.append("\(path): \(l) != \(r)")
            }
        case let (.bool(l), .bool(r)):
            if l != r { diffs.append("\(path): \(l) != \(r)") }
        case let (.string(l), .string(r)):
            if l != r { diffs.append("\(path): \"\(clip(l))\" != \"\(clip(r))\"") }
        case (.null, .null):
            break
        default:
            // Mixed kinds: allow the absent-equivalence classes to match each other
            // (null vs -1 vs false vs empty containers).
            if isAbsentEquivalent(lhs) && isAbsentEquivalent(rhs) { break }
            diffs.append("\(path): kind mismatch \(short(lhs)) vs \(short(rhs))")
        }
    }

    private enum Kind {
        case object([String: Any])
        case array([Any])
        case number(Double)
        case bool(Bool)
        case string(String)
        case null
    }

    private static func classify(_ value: Any) -> Kind {
        if value is NSNull { return .null }
        if let dict = value as? [String: Any] { return .object(dict) }
        if let arr = value as? [Any] { return .array(arr) }
        if let num = value as? NSNumber {
            if num === kCFBooleanTrue { return .bool(true) }
            if num === kCFBooleanFalse { return .bool(false) }
            return .number(num.doubleValue)
        }
        if let str = value as? String { return .string(str) }
        return .null
    }

    private static func isAbsentEquivalent(_ value: Any) -> Bool {
        switch classify(value) {
        case .null: return true
        case let .bool(b): return b == false
        case let .number(n): return n == -1
        case let .array(a): return a.isEmpty
        case let .object(o): return o.isEmpty
        case .string: return false
        }
    }

    private static func clip(_ s: String) -> String {
        s.count > 60 ? s.prefix(60) + "…" : s
    }

    private static func short(_ value: Any) -> String {
        switch classify(value) {
        case let .object(o): return "object(\(o.count) keys)"
        case let .array(a): return "array(\(a.count))"
        case let .number(n): return "\(n)"
        case let .bool(b): return "\(b)"
        case let .string(s): return "\"\(clip(s))\""
        case .null: return "null"
        }
    }
}

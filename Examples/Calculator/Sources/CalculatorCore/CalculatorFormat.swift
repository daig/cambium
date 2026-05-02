// CalculatorFormat.swift
//
// Tiny formatting helpers used across the Calculator example. No Cambium
// API showcase here — these exist purely so error messages, debug dumps,
// and REPL output share a single byte-range presentation.

import Cambium

/// Render a `TextRange` as `start..<end` in UTF-8 byte coordinates. All
/// byte positions in this example use this format so REPL commands like
/// `:cover` and `:edit` can be entered against output from `:tree` /
/// `:tokens` without translation.
public func format(_ range: TextRange) -> String {
    "\(range.start.rawValue)..<\(range.end.rawValue)"
}

/// Render a `CalculatorDiagnostic` as `severity: message at start..<end`.
public func formatDiagnostic(_ diagnostic: CalculatorDiagnostic) -> String {
    "\(diagnostic.severity): \(diagnostic.message) at \(format(diagnostic.range))"
}

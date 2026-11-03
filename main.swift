// The driver's entry point.
//
// These two lines used to sit at the end of TouchscreenDriver.swift. Swift
// allows top-level code only in a file named main.swift, so while they were
// there the module could not contain any other file -- which made the test
// binary, which compiles the same declarations with its own main, impossible
// to produce.
//
// tests/main.swift plays the same role for run_tests.sh. The two are never
// compiled together, which is exactly the constraint we want.

import Foundation

// Unbuffered, so output appears in the log as it happens
setbuf(stdout, nil)

main()

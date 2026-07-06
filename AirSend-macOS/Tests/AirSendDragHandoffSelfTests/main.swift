import AirSendDragHandoff
import CoreGraphics
import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw TestFailure(description: message)
    }
}

func testFirstRecognizedDragInsideActivationBandActivatesImmediately() throws {
    var policy = DragActivationPolicy(minimumTravel: 18)

    let decision = policy.decision(
        changeCount: 42,
        location: CGPoint(x: 420, y: 860),
        hasRecognizedPayload: true,
        isWithinActivationBand: true
    )

    try expect(decision.shouldActivate, "first recognized local-file drag inside activation band should activate immediately")
    try expect(decision.allowsFallbackRecovery, "immediate proximity activation should allow drop fallback recovery")
}

func testRecognizedDragOutsideActivationBandDoesNotActivate() throws {
    var policy = DragActivationPolicy(minimumTravel: 18)

    let decision = policy.decision(
        changeCount: 42,
        location: CGPoint(x: 420, y: 500),
        hasRecognizedPayload: true,
        isWithinActivationBand: false
    )

    try expect(!decision.shouldActivate, "recognized drag outside activation band should not activate")
}

func testUnrecognizedPointerDragInsideActivationBandShowsCandidateDropZoneAfterMovement() throws {
    var policy = DragActivationPolicy(minimumTravel: 18)

    let first = policy.decision(
        changeCount: 1,
        location: CGPoint(x: 420, y: 700),
        hasRecognizedPayload: false,
        isWithinActivationBand: false
    )
    try expect(!first.shouldActivate, "plain pointer movement outside activation band should not activate")

    let second = policy.decision(
        changeCount: 1,
        location: CGPoint(x: 420, y: 860),
        hasRecognizedPayload: false,
        isWithinActivationBand: true
    )

    try expect(second.shouldActivate, "unrecognized drag near status bar should show a candidate drop zone")
    try expect(!second.allowsFallbackRecovery, "candidate preview without file URLs should not use fallback file sending")
}

let tests: [(String, () throws -> Void)] = [
    ("firstRecognizedDragInsideActivationBandActivatesImmediately", testFirstRecognizedDragInsideActivationBandActivatesImmediately),
    ("recognizedDragOutsideActivationBandDoesNotActivate", testRecognizedDragOutsideActivationBandDoesNotActivate),
    ("unrecognizedPointerDragInsideActivationBandShowsCandidateDropZoneAfterMovement", testUnrecognizedPointerDragInsideActivationBandShowsCandidateDropZoneAfterMovement),
]

do {
    for (name, test) in tests {
        do {
            try test()
        } catch {
            throw TestFailure(description: "\(name): \(error)")
        }
    }
    print("AirSendDragHandoffSelfTests passed")
} catch {
    fputs("AirSendDragHandoffSelfTests failed: \(error)\n", stderr)
    exit(1)
}

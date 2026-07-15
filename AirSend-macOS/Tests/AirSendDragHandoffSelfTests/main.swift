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

func testFreshRecognizedDragInsideActivationBandActivatesImmediately() throws {
    var policy = DragActivationPolicy(minimumTravel: 18)

    let decision = policy.decision(
        changeCount: 42,
        location: CGPoint(x: 420, y: 860),
        hasRecognizedPayload: true,
        hasFreshPayloadEvidence: true,
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
        hasFreshPayloadEvidence: true,
        isWithinActivationBand: false
    )

    try expect(!decision.shouldActivate, "recognized drag outside activation band should not activate")
}

func testPlainPointerDragInsideActivationBandDoesNotShowCandidateDropZone() throws {
    var policy = DragActivationPolicy(minimumTravel: 18)

    let first = policy.decision(
        changeCount: 1,
        location: CGPoint(x: 420, y: 700),
        hasRecognizedPayload: false,
        hasFreshPayloadEvidence: false,
        isWithinActivationBand: false
    )
    try expect(!first.shouldActivate, "plain pointer movement outside activation band should not activate")

    let second = policy.decision(
        changeCount: 1,
        location: CGPoint(x: 420, y: 860),
        hasRecognizedPayload: false,
        hasFreshPayloadEvidence: false,
        isWithinActivationBand: true
    )

    try expect(!second.shouldActivate, "plain pointer movement inside activation band should not activate")
    try expect(!second.allowsFallbackRecovery, "plain pointer movement should not use fallback file sending")
}

func testUnrecognizedDragPasteboardInsideActivationBandDoesNotShowDropZone() throws {
    var policy = DragActivationPolicy(minimumTravel: 18)

    let first = policy.decision(
        changeCount: 1,
        location: CGPoint(x: 420, y: 700),
        hasRecognizedPayload: false,
        hasFreshPayloadEvidence: true,
        isWithinActivationBand: false
    )
    try expect(!first.shouldActivate, "drag pasteboard movement outside activation band should not activate")

    let second = policy.decision(
        changeCount: 1,
        location: CGPoint(x: 420, y: 860),
        hasRecognizedPayload: false,
        hasFreshPayloadEvidence: true,
        isWithinActivationBand: true
    )

    try expect(!second.shouldActivate, "pasteboard metadata without verified local-file URLs must not show the drop zone")
    try expect(!second.allowsFallbackRecovery, "unverified payloads must not use fallback file sending")
}

func testDragPasteboardChangeMustDifferFromIdleBaseline() throws {
    try expect(
        DragPasteboardEvidence.hasFreshChangeCount(
            idleChangeCount: 41,
            currentChangeCount: 42
        ),
        "a changed drag pasteboard should count as fresh gesture evidence"
    )

    try expect(
        !DragPasteboardEvidence.hasFreshChangeCount(
            idleChangeCount: 42,
            currentChangeCount: 42
        ),
        "unchanged stale drag pasteboard contents must not count as a new gesture"
    )
    try expect(
        !DragPasteboardEvidence.hasFreshChangeCount(
            idleChangeCount: nil,
            currentChangeCount: 42
        ),
        "missing idle evidence must fail closed instead of treating residual metadata as fresh"
    )
}

func testStaleRecognizedPayloadDoesNotActivateOnClickJitterOrTravel() throws {
    var policy = DragActivationPolicy(minimumTravel: 18)

    let jitter = policy.decision(
        changeCount: 42,
        location: CGPoint(x: 420, y: 860),
        hasRecognizedPayload: true,
        hasFreshPayloadEvidence: false,
        isWithinActivationBand: true
    )
    try expect(!jitter.shouldActivate, "a click with stale file metadata must not show the drop zone")
    try expect(!jitter.allowsFallbackRecovery, "a stale click must never be allowed to resend an old file")

    let moved = policy.decision(
        changeCount: 42,
        location: CGPoint(x: 470, y: 900),
        hasRecognizedPayload: true,
        hasFreshPayloadEvidence: false,
        isWithinActivationBand: true
    )
    try expect(!moved.shouldActivate, "pointer movement alone must not turn stale file metadata into a drag session")
    try expect(!moved.allowsFallbackRecovery, "stale metadata must remain ineligible for fallback after movement")
}

func testMovedWindowUnderPointerIsRecognizedAsWindowDrag() throws {
    let initialFrames: [CGWindowID: CGRect] = [
        7: CGRect(x: 100, y: 100, width: 800, height: 600),
    ]
    let currentFrames: [CGWindowID: CGRect] = [
        7: CGRect(x: 130, y: 118, width: 800, height: 600),
    ]

    try expect(
        WindowDragEvidence.hasMovedWindowFromDragStart(
            initialFrames: initialFrames,
            currentFrames: currentFrames,
            dragStartPointerLocation: CGPoint(x: 420, y: 180)
        ),
        "a top-level window moving with the pointer should be classified as a window drag"
    )
}

func testUnrelatedWindowMovementDoesNotSuppressFileDrag() throws {
    let initialFrames: [CGWindowID: CGRect] = [
        7: CGRect(x: 100, y: 100, width: 800, height: 600),
    ]
    let currentFrames: [CGWindowID: CGRect] = [
        7: CGRect(x: 130, y: 118, width: 800, height: 600),
    ]

    try expect(
        !WindowDragEvidence.hasMovedWindowFromDragStart(
            initialFrames: initialFrames,
            currentFrames: currentFrames,
            dragStartPointerLocation: CGPoint(x: 1100, y: 180)
        ),
        "movement from a window away from the pointer should not suppress a file drag"
    )
}

func testWindowDragRemainsRecognizedAfterPointerReachesMenuBar() throws {
    let initialFrames: [CGWindowID: CGRect] = [
        7: CGRect(x: 100, y: 100, width: 800, height: 600),
    ]
    let currentFrames: [CGWindowID: CGRect] = [
        7: CGRect(x: 130, y: 33, width: 800, height: 600),
    ]

    try expect(
        WindowDragEvidence.hasMovedWindowFromDragStart(
            initialFrames: initialFrames,
            currentFrames: currentFrames,
            dragStartPointerLocation: CGPoint(x: 420, y: 120)
        ),
        "a moved window should remain classified as a window drag after the pointer leaves it for the menu bar"
    )
}

func testPreviewUsesTransitionCorridorBeforeEnteringCompactTarget() throws {
    try expect(
        DragPreviewVisibilityPolicy.shouldKeepPreviewVisible(
            isWithinTransitionCorridor: true,
            isWithinCompactKeepalive: false,
            hasEnteredCompactDropTarget: false,
            isAcceptingDragSession: false,
            isHoveringDropTarget: false
        ),
        "the initial handoff corridor should keep the preview visible while approaching the drop target"
    )

    try expect(
        !DragPreviewVisibilityPolicy.shouldKeepPreviewVisible(
            isWithinTransitionCorridor: false,
            isWithinCompactKeepalive: false,
            hasEnteredCompactDropTarget: false,
            isAcceptingDragSession: false,
            isHoveringDropTarget: false
        ),
        "the preview should be eligible for dismissal after leaving the initial corridor"
    )
}

func testPreviewShrinksToCompactTargetAfterEntry() throws {
    try expect(
        !DragPreviewVisibilityPolicy.shouldKeepPreviewVisible(
            isWithinTransitionCorridor: true,
            isWithinCompactKeepalive: false,
            hasEnteredCompactDropTarget: true,
            isAcceptingDragSession: false,
            isHoveringDropTarget: false
        ),
        "the wide transition corridor must stop keeping the preview alive after the compact target is entered"
    )

    try expect(
        DragPreviewVisibilityPolicy.shouldKeepPreviewVisible(
            isWithinTransitionCorridor: false,
            isWithinCompactKeepalive: true,
            hasEnteredCompactDropTarget: true,
            isAcceptingDragSession: false,
            isHoveringDropTarget: false
        ),
        "the compact keepalive region should prevent edge flicker after entry"
    )
}

func testTransitionCorridorConnectsActivationPointWithoutBecomingScreenWide() throws {
    let target = CGRect(x: 700, y: 500, width: 240, height: 210)
    let activation = CGPoint(x: 600, y: 860)

    try expect(
        DragTransitionCorridor.contains(
            CGPoint(x: 650, y: 785),
            from: activation,
            to: target
        ),
        "a point on the route from activation to the target should remain in the handoff corridor"
    )

    try expect(
        !DragTransitionCorridor.contains(
            CGPoint(x: 500, y: 785),
            from: activation,
            to: target
        ),
        "the handoff corridor should stay narrow instead of keeping a large part of the screen active"
    )

    try expect(
        DragTransitionCorridor.contains(
            CGPoint(x: 820, y: 600),
            from: activation,
            to: target
        ),
        "the visible drop target itself should always be part of the corridor"
    )
}

let tests: [(String, () throws -> Void)] = [
    ("freshRecognizedDragInsideActivationBandActivatesImmediately", testFreshRecognizedDragInsideActivationBandActivatesImmediately),
    ("recognizedDragOutsideActivationBandDoesNotActivate", testRecognizedDragOutsideActivationBandDoesNotActivate),
    ("plainPointerDragInsideActivationBandDoesNotShowCandidateDropZone", testPlainPointerDragInsideActivationBandDoesNotShowCandidateDropZone),
    ("unrecognizedDragPasteboardInsideActivationBandDoesNotShowDropZone", testUnrecognizedDragPasteboardInsideActivationBandDoesNotShowDropZone),
    ("dragPasteboardChangeMustDifferFromIdleBaseline", testDragPasteboardChangeMustDifferFromIdleBaseline),
    ("staleRecognizedPayloadDoesNotActivateOnClickJitterOrTravel", testStaleRecognizedPayloadDoesNotActivateOnClickJitterOrTravel),
    ("movedWindowUnderPointerIsRecognizedAsWindowDrag", testMovedWindowUnderPointerIsRecognizedAsWindowDrag),
    ("unrelatedWindowMovementDoesNotSuppressFileDrag", testUnrelatedWindowMovementDoesNotSuppressFileDrag),
    ("windowDragRemainsRecognizedAfterPointerReachesMenuBar", testWindowDragRemainsRecognizedAfterPointerReachesMenuBar),
    ("previewUsesTransitionCorridorBeforeEnteringCompactTarget", testPreviewUsesTransitionCorridorBeforeEnteringCompactTarget),
    ("previewShrinksToCompactTargetAfterEntry", testPreviewShrinksToCompactTargetAfterEntry),
    ("transitionCorridorConnectsActivationPointWithoutBecomingScreenWide", testTransitionCorridorConnectsActivationPointWithoutBecomingScreenWide),
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

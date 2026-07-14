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
        hasDragPasteboardEvidence: true,
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
        hasDragPasteboardEvidence: true,
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
        hasDragPasteboardEvidence: false,
        isWithinActivationBand: false
    )
    try expect(!first.shouldActivate, "plain pointer movement outside activation band should not activate")

    let second = policy.decision(
        changeCount: 1,
        location: CGPoint(x: 420, y: 860),
        hasRecognizedPayload: false,
        hasDragPasteboardEvidence: false,
        isWithinActivationBand: true
    )

    try expect(!second.shouldActivate, "plain pointer movement inside activation band should not activate")
    try expect(!second.allowsFallbackRecovery, "plain pointer movement should not use fallback file sending")
}

func testUnrecognizedDragPasteboardInsideActivationBandShowsCandidateDropZoneAfterMovement() throws {
    var policy = DragActivationPolicy(minimumTravel: 18)

    let first = policy.decision(
        changeCount: 1,
        location: CGPoint(x: 420, y: 700),
        hasRecognizedPayload: false,
        hasDragPasteboardEvidence: true,
        isWithinActivationBand: false
    )
    try expect(!first.shouldActivate, "drag pasteboard movement outside activation band should not activate")

    let second = policy.decision(
        changeCount: 1,
        location: CGPoint(x: 420, y: 860),
        hasRecognizedPayload: false,
        hasDragPasteboardEvidence: true,
        isWithinActivationBand: true
    )

    try expect(second.shouldActivate, "unrecognized drag near status bar should show a candidate drop zone")
    try expect(!second.allowsFallbackRecovery, "candidate preview without file URLs should not use fallback file sending")
}

func testFreshDragPasteboardChangeCountsAsEvidenceBeforePayloadIsReadable() throws {
    try expect(
        DragPasteboardEvidence.hasPotentialDragSession(
            hasFreshChangeCount: true,
            hasReadablePayloadMetadata: false
        ),
        "fresh drag pasteboard change should count as candidate evidence even before file metadata is readable"
    )

    try expect(
        !DragPasteboardEvidence.hasPotentialDragSession(
            hasFreshChangeCount: false,
            hasReadablePayloadMetadata: false
        ),
        "plain window movement without a fresh drag pasteboard change should not count as candidate evidence"
    )
}

func testReadablePayloadMetadataCountsAsEvidenceWhenChangeCountIsStable() throws {
    try expect(
        DragPasteboardEvidence.hasPotentialDragSession(
            hasFreshChangeCount: false,
            hasReadablePayloadMetadata: true
        ),
        "readable drag metadata should preserve wide activation when drag pasteboard change counts are stable"
    )
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

func testPreviewDismissesAfterLeavingDropZoneKeepaliveRegion() throws {
    try expect(
        !DragPreviewVisibilityPolicy.shouldKeepPreviewVisible(
            isWithinDropZoneKeepalive: false,
            isAcceptingDragSession: false,
            isHoveringDropTarget: false
        ),
        "an active preview should dismiss once the pointer leaves the compact drop-zone keepalive region"
    )

    try expect(
        DragPreviewVisibilityPolicy.shouldKeepPreviewVisible(
            isWithinDropZoneKeepalive: true,
            isAcceptingDragSession: false,
            isHoveringDropTarget: false
        ),
        "the compact drop-zone keepalive region should prevent edge flicker"
    )
}

let tests: [(String, () throws -> Void)] = [
    ("firstRecognizedDragInsideActivationBandActivatesImmediately", testFirstRecognizedDragInsideActivationBandActivatesImmediately),
    ("recognizedDragOutsideActivationBandDoesNotActivate", testRecognizedDragOutsideActivationBandDoesNotActivate),
    ("plainPointerDragInsideActivationBandDoesNotShowCandidateDropZone", testPlainPointerDragInsideActivationBandDoesNotShowCandidateDropZone),
    ("unrecognizedDragPasteboardInsideActivationBandShowsCandidateDropZoneAfterMovement", testUnrecognizedDragPasteboardInsideActivationBandShowsCandidateDropZoneAfterMovement),
    ("freshDragPasteboardChangeCountsAsEvidenceBeforePayloadIsReadable", testFreshDragPasteboardChangeCountsAsEvidenceBeforePayloadIsReadable),
    ("readablePayloadMetadataCountsAsEvidenceWhenChangeCountIsStable", testReadablePayloadMetadataCountsAsEvidenceWhenChangeCountIsStable),
    ("movedWindowUnderPointerIsRecognizedAsWindowDrag", testMovedWindowUnderPointerIsRecognizedAsWindowDrag),
    ("unrelatedWindowMovementDoesNotSuppressFileDrag", testUnrelatedWindowMovementDoesNotSuppressFileDrag),
    ("windowDragRemainsRecognizedAfterPointerReachesMenuBar", testWindowDragRemainsRecognizedAfterPointerReachesMenuBar),
    ("previewDismissesAfterLeavingDropZoneKeepaliveRegion", testPreviewDismissesAfterLeavingDropZoneKeepaliveRegion),
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

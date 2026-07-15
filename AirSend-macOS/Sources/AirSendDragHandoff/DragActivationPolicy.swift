import CoreGraphics

public struct DragActivationDecision: Equatable {
    public let shouldActivate: Bool
    public let allowsFallbackRecovery: Bool

    public init(shouldActivate: Bool, allowsFallbackRecovery: Bool) {
        self.shouldActivate = shouldActivate
        self.allowsFallbackRecovery = allowsFallbackRecovery
    }
}

public enum DragPasteboardEvidence {
    public static func hasPotentialDragSession(
        hasFreshChangeCount: Bool,
        hasReadablePayloadMetadata: Bool
    ) -> Bool {
        hasFreshChangeCount || hasReadablePayloadMetadata
    }
}

public enum WindowDragEvidence {
    public static func hasMovedWindowFromDragStart(
        initialFrames: [CGWindowID: CGRect],
        currentFrames: [CGWindowID: CGRect],
        dragStartPointerLocation: CGPoint,
        minimumOriginTravel: CGFloat = 3
    ) -> Bool {
        for (windowID, initialFrame) in initialFrames {
            guard initialFrame.contains(dragStartPointerLocation),
                  let currentFrame = currentFrames[windowID] else {
                continue
            }

            let dx = currentFrame.origin.x - initialFrame.origin.x
            let dy = currentFrame.origin.y - initialFrame.origin.y
            if hypot(dx, dy) >= minimumOriginTravel {
                return true
            }
        }
        return false
    }
}

public enum DragPreviewVisibilityPolicy {
    public static func shouldKeepPreviewVisible(
        isWithinDropZoneKeepalive: Bool,
        isAcceptingDragSession: Bool,
        isHoveringDropTarget: Bool
    ) -> Bool {
        isWithinDropZoneKeepalive || isAcceptingDragSession || isHoveringDropTarget
    }
}

public struct DragActivationPolicy {
    public private(set) var observedPasteboardChangeCount: Int?
    public private(set) var observedStartPoint: CGPoint?
    public private(set) var observedMovedEnough = false
    public private(set) var pointerDragStartPoint: CGPoint?
    public private(set) var pointerDragMovedEnough = false

    private let minimumTravel: CGFloat

    public init(minimumTravel: CGFloat = 18) {
        self.minimumTravel = minimumTravel
    }

    public mutating func reset() {
        resetRecognizedPayload()
        pointerDragStartPoint = nil
        pointerDragMovedEnough = false
    }

    private mutating func resetRecognizedPayload() {
        observedPasteboardChangeCount = nil
        observedStartPoint = nil
        observedMovedEnough = false
    }

    @discardableResult
    public mutating func observePointerDrag(location: CGPoint) -> Bool {
        if pointerDragStartPoint == nil {
            pointerDragStartPoint = location
            pointerDragMovedEnough = false
            return false
        }

        guard let pointerDragStartPoint else { return pointerDragMovedEnough }
        let dx = location.x - pointerDragStartPoint.x
        let dy = location.y - pointerDragStartPoint.y
        if hypot(dx, dy) >= minimumTravel {
            pointerDragMovedEnough = true
        }
        return pointerDragMovedEnough
    }

    @discardableResult
    public mutating func observe(changeCount: Int, location: CGPoint, hasRecognizedPayload: Bool) -> Bool {
        guard hasRecognizedPayload else {
            resetRecognizedPayload()
            return false
        }

        if observedPasteboardChangeCount != changeCount {
            observedPasteboardChangeCount = changeCount
            observedStartPoint = location
            observedMovedEnough = false
            return false
        }

        guard let observedStartPoint else { return observedMovedEnough }
        let dx = location.x - observedStartPoint.x
        let dy = location.y - observedStartPoint.y
        if hypot(dx, dy) >= minimumTravel {
            observedMovedEnough = true
        }
        return observedMovedEnough
    }

    public mutating func decision(
        changeCount: Int,
        location: CGPoint,
        hasRecognizedPayload: Bool,
        hasDragPasteboardEvidence: Bool,
        isWithinActivationBand: Bool
    ) -> DragActivationDecision {
        observePointerDrag(location: location)
        let isFirstRecognizedPayload = hasRecognizedPayload && observedPasteboardChangeCount != changeCount
        let hasMovedEnough = observe(
            changeCount: changeCount,
            location: location,
            hasRecognizedPayload: hasRecognizedPayload
        )
        let shouldActivate = isWithinActivationBand && (hasRecognizedPayload || hasDragPasteboardEvidence)
        return DragActivationDecision(
            shouldActivate: shouldActivate,
            allowsFallbackRecovery: shouldActivate && hasRecognizedPayload && (isFirstRecognizedPayload || hasMovedEnough)
        )
    }
}

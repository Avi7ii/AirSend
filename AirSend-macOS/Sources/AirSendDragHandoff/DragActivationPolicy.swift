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
        isWithinTransitionCorridor: Bool,
        isWithinCompactKeepalive: Bool,
        hasEnteredCompactDropTarget: Bool,
        isAcceptingDragSession: Bool,
        isHoveringDropTarget: Bool
    ) -> Bool {
        if isAcceptingDragSession || isHoveringDropTarget {
            return true
        }
        if hasEnteredCompactDropTarget {
            return isWithinCompactKeepalive
        }
        return isWithinTransitionCorridor || isWithinCompactKeepalive
    }
}

public enum DragTransitionCorridor {
    public static func contains(
        _ point: CGPoint,
        from activationPoint: CGPoint,
        to targetFrame: CGRect,
        corridorRadius: CGFloat = 42,
        targetInset: CGFloat = 10
    ) -> Bool {
        guard !targetFrame.isNull, !targetFrame.isInfinite, !targetFrame.isEmpty else {
            return false
        }

        let inset = max(0, targetInset)
        let expandedTarget = targetFrame.insetBy(dx: -inset, dy: -inset)
        if expandedTarget.contains(point) {
            return true
        }

        let destination = CGPoint(
            x: min(max(activationPoint.x, expandedTarget.minX), expandedTarget.maxX),
            y: min(max(activationPoint.y, expandedTarget.minY), expandedTarget.maxY)
        )
        let radius = max(0, corridorRadius)
        return squaredDistance(
            from: point,
            toSegmentFrom: activationPoint,
            to: destination
        ) <= radius * radius
    }

    private static func squaredDistance(
        from point: CGPoint,
        toSegmentFrom start: CGPoint,
        to end: CGPoint
    ) -> CGFloat {
        let segmentX = end.x - start.x
        let segmentY = end.y - start.y
        let segmentLengthSquared = segmentX * segmentX + segmentY * segmentY
        guard segmentLengthSquared > .ulpOfOne else {
            let dx = point.x - start.x
            let dy = point.y - start.y
            return dx * dx + dy * dy
        }

        let projection = ((point.x - start.x) * segmentX + (point.y - start.y) * segmentY)
            / segmentLengthSquared
        let t = min(1, max(0, projection))
        let closest = CGPoint(
            x: start.x + t * segmentX,
            y: start.y + t * segmentY
        )
        let dx = point.x - closest.x
        let dy = point.y - closest.y
        return dx * dx + dy * dy
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
        isWithinActivationBand: Bool
    ) -> DragActivationDecision {
        observePointerDrag(location: location)
        let isFirstRecognizedPayload = hasRecognizedPayload && observedPasteboardChangeCount != changeCount
        let hasMovedEnough = observe(
            changeCount: changeCount,
            location: location,
            hasRecognizedPayload: hasRecognizedPayload
        )
        let shouldActivate = isWithinActivationBand && hasRecognizedPayload
        return DragActivationDecision(
            shouldActivate: shouldActivate,
            allowsFallbackRecovery: shouldActivate && hasRecognizedPayload && (isFirstRecognizedPayload || hasMovedEnough)
        )
    }
}

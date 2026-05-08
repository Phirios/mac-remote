import SwiftUI
import UIKit

/// Multi-touch trackpad. Wraps a UIView so we get raw touch events
/// (SwiftUI's gesture system doesn't expose them cleanly enough for this).
///
/// Gestures:
/// - 1-finger drag       → relative cursor move
/// - 1-finger tap        → left click
/// - 2-finger tap        → right click
/// - 2-finger drag       → scroll
/// - 1-finger long-press → mouse-down (drag); release ends it
struct TrackpadView: UIViewRepresentable {
    @EnvironmentObject var state: AppState

    func makeUIView(context: Context) -> TrackpadUIView {
        let v = TrackpadUIView()
        v.state = state
        return v
    }
    func updateUIView(_ v: TrackpadUIView, context: Context) {
        v.state = state
    }
}

final class TrackpadUIView: UIView {
    weak var state: AppState?

    private var touchInfo: [ObjectIdentifier: TouchInfo] = [:]
    private var dragHeld = false
    private var longPressWorkItem: DispatchWorkItem?

    private let tapMaxDuration: TimeInterval = 0.35
    private let tapMaxMovement: CGFloat = 22
    private let longPressDuration: TimeInterval = 0.35

    // Scroll momentum
    private var scrollVelocity: CGPoint = .zero
    private var wasScrolling = false

    // Cursor momentum
    private var cursorVelocity: CGPoint = .zero
    private var wasCursorMoving = false

    // 3-finger gesture
    private var threeFingerDelta: CGPoint = .zero
    private var wasThreeFinger = false
    private let threeFingerThreshold: CGFloat = 30

    // Paint trail
    private var trailLastPoint: CGPoint?
    private let trailStep: CGFloat = 6

    // Drag-hold sonar rings
    private var dragRingTimer: Timer?
    private var dragRingOrigin: CGPoint = .zero

    // Shared momentum display link
    private var momentumLink: CADisplayLink?
    private var momentumMode: MomentumMode = .none
    private enum MomentumMode { case none, scroll, cursor }
    private let momentumDecay: CGFloat = 0.90
    private let momentumThreshold: CGFloat = 0.4

    // Cursor smoothing (exponential moving average)
    private var smoothDx: CGFloat = 0
    private var smoothDy: CGFloat = 0
    private let cursorSmoothing: CGFloat = 0.5

    private struct TouchInfo {
        let start: CGPoint
        var last: CGPoint
        let startTime: TimeInterval
        var moved: Bool = false
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.10, alpha: 1.0)
        layer.cornerRadius = 12
        layer.borderColor = UIColor(white: 0.18, alpha: 1.0).cgColor
        layer.borderWidth = 1
        isMultipleTouchEnabled = true
        isExclusiveTouch = true
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: touches
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let now = CACurrentMediaTime()
        for t in touches {
            let p = t.location(in: self)
            touchInfo[ObjectIdentifier(t)] = TouchInfo(start: p, last: p, startTime: now)
        }
        // Reset all last positions on finger count change to prevent delta jump
        if touchInfo.count >= 2, let all = event?.allTouches {
            for t in all { touchInfo[ObjectIdentifier(t)]?.last = t.location(in: self) }
            smoothDx = 0; smoothDy = 0; cursorVelocity = .zero
        }
        stopMomentum()
        // Long-press → start drag
        if touchInfo.count == 1 {
            scheduleLongPress()
            trailLastPoint = touches.first?.location(in: self)
        } else {
            cancelLongPress()
            trailLastPoint = nil
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let state else { return }
        // Snapshot what currently has fingers down
        let activeCount = touchInfo.count

        if activeCount >= 3 {
            var dx: CGFloat = 0, dy: CGFloat = 0, n = 0
            for t in touches {
                let key = ObjectIdentifier(t)
                guard var info = touchInfo[key] else { continue }
                let p = t.location(in: self)
                dx += p.x - info.last.x
                dy += p.y - info.last.y
                n += 1
                info.last = p
                info.moved = true
                touchInfo[key] = info
            }
            if n > 0 {
                threeFingerDelta.x += dx / CGFloat(n)
                threeFingerDelta.y += dy / CGFloat(n)
                wasThreeFinger = true
            }
        } else if activeCount == 2 {
            var dx: CGFloat = 0, dy: CGFloat = 0, n = 0
            for t in touches {
                let key = ObjectIdentifier(t)
                guard var info = touchInfo[key] else { continue }
                let p = t.location(in: self)
                dx += p.x - info.last.x
                dy += p.y - info.last.y
                n += 1
                info.last = p
                if hypot(p.x - info.start.x, p.y - info.start.y) > tapMaxMovement {
                    info.moved = true
                }
                touchInfo[key] = info
            }
            if n > 0 {
                let s = state.settings.scrollSensitivity
                let sdx = -dx * s / CGFloat(n)
                let sdy = -dy * s / CGFloat(n)
                // Rolling velocity average for momentum
                scrollVelocity = CGPoint(
                    x: scrollVelocity.x * 0.4 + sdx * 0.6,
                    y: scrollVelocity.y * 0.4 + sdy * 0.6
                )
                wasScrolling = true
                state.scroll(dx: sdx, dy: sdy)
            }
        } else if activeCount == 1 {
            for t in touches {
                let key = ObjectIdentifier(t)
                guard var info = touchInfo[key] else { continue }
                let p = t.location(in: self)
                let rawDx = (p.x - info.last.x) * state.settings.sensitivity
                let rawDy = (p.y - info.last.y) * state.settings.sensitivity
                // Smooth cursor movement with EMA
                smoothDx = smoothDx * cursorSmoothing + rawDx * (1 - cursorSmoothing)
                smoothDy = smoothDy * cursorSmoothing + rawDy * (1 - cursorSmoothing)
                // Rolling velocity for momentum
                cursorVelocity = CGPoint(
                    x: cursorVelocity.x * 0.4 + smoothDx * 0.6,
                    y: cursorVelocity.y * 0.4 + smoothDy * 0.6
                )
                info.last = p
                if hypot(p.x - info.start.x, p.y - info.start.y) > tapMaxMovement {
                    info.moved = true
                    wasCursorMoving = true
                    cancelLongPress()
                }
                touchInfo[key] = info
                if let last = trailLastPoint, hypot(p.x - last.x, p.y - last.y) >= trailStep {
                    addTrailSegment(from: last, to: p)
                    trailLastPoint = p
                }
                state.mouseMove(dx: smoothDx, dy: smoothDy)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let state else { return }
        cancelLongPress()
        trailLastPoint = nil
        let now = CACurrentMediaTime()

        // Determine intent before mutating touchInfo: were 2 fingers ever down at once?
        let endingCount = touches.count
        let wasMultiTouchSession = (touchInfo.count > endingCount) || (endingCount > 1)

        // Find if any of the ending touches were quick + still
        var quickStillEndings: [TouchInfo] = []
        for t in touches {
            let key = ObjectIdentifier(t)
            guard let info = touchInfo.removeValue(forKey: key) else { continue }
            let dur = now - info.startTime
            if !info.moved && dur < tapMaxDuration {
                quickStillEndings.append(info)
            }
        }

        // Reset remaining touches' last position to prevent delta jump on finger count change
        if !touchInfo.isEmpty, let all = event?.allTouches {
            for t in all where !touches.contains(t) {
                touchInfo[ObjectIdentifier(t)]?.last = t.location(in: self)
            }
            smoothDx = 0; smoothDy = 0; cursorVelocity = .zero
        }

        // If a drag is held, releasing the last finger ends it.
        if dragHeld && touchInfo.isEmpty {
            dragHeld = false
            stopDragRings()
            state.mouseUp("left")
            return
        }

        // Fire 3-finger swipe gesture
        if touchInfo.isEmpty && wasThreeFinger {
            wasThreeFinger = false
            let dx = threeFingerDelta.x
            let dy = threeFingerDelta.y
            threeFingerDelta = .zero
            if state.settings.threeFingerGestures && max(abs(dx), abs(dy)) >= threeFingerThreshold {
                if abs(dx) > abs(dy) {
                    state.combo(dx < 0 ? "right" : "left", mods: ["ctrl"])
                } else {
                    state.combo(dy < 0 ? "up" : "down", mods: ["ctrl"])
                }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            return
        }

        // Start scroll momentum when 2-finger scroll ends
        if touchInfo.isEmpty && wasScrolling {
            wasScrolling = false
            if state.settings.smoothScroll { startMomentum(mode: .scroll) } else { scrollVelocity = .zero }
        }

        // Start cursor momentum when 1-finger drag ends
        if touchInfo.isEmpty && wasCursorMoving && !dragHeld {
            wasCursorMoving = false
            if state.settings.smoothScroll { startMomentum(mode: .cursor) } else { cursorVelocity = .zero }
        }

        // Tap classification:
        // - 2 fingers ended ~together AND no movement → right-click (one event)
        // - 1 finger ended quickly + no other fingers were involved → left-click
        if quickStillEndings.count >= 2 && touchInfo.isEmpty {
            state.click("right")
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            for info in quickStillEndings.prefix(2) { showRipple(at: info.last) }
        } else if quickStillEndings.count == 1 && touchInfo.isEmpty && !wasMultiTouchSession {
            state.click("left")
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if let info = quickStillEndings.first { showRipple(at: info.last) }
        }
        // Else: ignore (movement, or multi-touch session that didn't qualify as a tap)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelLongPress()
        trailLastPoint = nil
        stopMomentum()
        if dragHeld {
            dragHeld = false
            stopDragRings()
            state?.mouseUp("left")
        }
        for t in touches { touchInfo.removeValue(forKey: ObjectIdentifier(t)) }
    }

    // MARK: momentum scroll

    private func startMomentum(mode: MomentumMode) {
        let vel = mode == .scroll ? scrollVelocity : cursorVelocity
        guard hypot(vel.x, vel.y) > momentumThreshold else {
            scrollVelocity = .zero; cursorVelocity = .zero
            return
        }
        momentumLink?.invalidate()
        momentumMode = mode
        let link = CADisplayLink(target: self, selector: #selector(momentumStep))
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    @objc private func momentumStep() {
        switch momentumMode {
        case .scroll:
            scrollVelocity = CGPoint(x: scrollVelocity.x * momentumDecay,
                                     y: scrollVelocity.y * momentumDecay)
            if hypot(scrollVelocity.x, scrollVelocity.y) < momentumThreshold { stopMomentum(); return }
            state?.scroll(dx: scrollVelocity.x, dy: scrollVelocity.y)
        case .cursor:
            cursorVelocity = CGPoint(x: cursorVelocity.x * momentumDecay,
                                     y: cursorVelocity.y * momentumDecay)
            if hypot(cursorVelocity.x, cursorVelocity.y) < momentumThreshold { stopMomentum(); return }
            state?.mouseMove(dx: cursorVelocity.x, dy: cursorVelocity.y)
        case .none:
            stopMomentum()
        }
    }

    private func stopMomentum() {
        momentumLink?.invalidate()
        momentumLink = nil
        momentumMode = .none
        scrollVelocity = .zero
        cursorVelocity = .zero
        wasScrolling = false
        wasCursorMoving = false
        wasThreeFinger = false
        threeFingerDelta = .zero
        smoothDx = 0
        smoothDy = 0
    }

    // MARK: drag sonar animation

    private func startDragRings(at point: CGPoint) {
        dragRingOrigin = point
        stopDragRings()
        addDragRing()
        dragRingTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            self?.addDragRing()
        }
    }

    private func addDragRing() {
        let ring = CAShapeLayer()
        let r: CGFloat = 10
        ring.path = UIBezierPath(ovalIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2)).cgPath
        ring.position = dragRingOrigin
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor.white.withAlphaComponent(0.55).cgColor
        ring.lineWidth = 1.5
        ring.lineDashPattern = [3, 6]

        layer.addSublayer(ring)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.6; scale.toValue = 4.8

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.75; fade.toValue = 0.0

        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 1.0
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "sonar")
        CATransaction.commit()
    }

    private func stopDragRings() {
        dragRingTimer?.invalidate()
        dragRingTimer = nil
    }

    // MARK: paint trail

    private func addTrailSegment(from: CGPoint, to: CGPoint) {
        let seg = CAShapeLayer()
        let path = UIBezierPath()
        path.move(to: from)
        path.addLine(to: to)
        seg.path = path.cgPath
        seg.fillColor = UIColor.clear.cgColor
        seg.strokeColor = UIColor.white.withAlphaComponent(0.55).cgColor
        seg.lineWidth = 2.0
        seg.lineCap = .round
        layer.addSublayer(seg)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.55; fade.toValue = 0.0
        fade.duration = 0.45; fade.fillMode = .forwards; fade.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { seg.removeFromSuperlayer() }
        seg.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    // MARK: ripple animation

    private func showRipple(at point: CGPoint) {
        let ripple = CALayer()
        let size: CGFloat = 72
        ripple.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        ripple.position = point
        ripple.cornerRadius = size / 2
        ripple.backgroundColor = UIColor.white.withAlphaComponent(0.18).cgColor
        ripple.borderColor = UIColor.white.withAlphaComponent(0.45).cgColor
        ripple.borderWidth = 1.5
        layer.addSublayer(ripple)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.15
        scale.toValue = 1.0

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0

        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.38
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { ripple.removeFromSuperlayer() }
        ripple.add(group, forKey: "ripple")
        CATransaction.commit()
    }

    // MARK: long-press → drag
    private func scheduleLongPress() {
        cancelLongPress()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let state = self.state else { return }
            // Only start drag if exactly one finger is down and hasn't moved
            guard self.touchInfo.count == 1, let info = self.touchInfo.values.first, !info.moved else { return }
            self.dragHeld = true
            state.mouseDown("left")
            self.startDragRings(at: info.last)
            let gen = UIImpactFeedbackGenerator(style: .medium)
            gen.impactOccurred()
        }
        longPressWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + longPressDuration, execute: work)
    }
    private func cancelLongPress() {
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
    }
}

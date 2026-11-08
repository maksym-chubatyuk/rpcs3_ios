import GameController
import QuartzCore
import UIKit

// Ported from the win app's TouchController (same layout and touch handling), with the
// buttons of a PlayStation 3 controller and RPCS3 as the receiver.

/// How the on-screen controls are laid out: their size and opacity, and where each group sits.
/// Kept for all games, and for a game that has its own.
struct TouchLayout: Codable, Equatable {
    /// The face buttons with R1/R2, the D-pad with L1/L2, and Select/PS/Start.
    enum Group: String, Codable, CaseIterable { case face, dpad, system }

    struct Placement: Codable, Equatable {
        /// Moved from the default place by these fractions of the screen's width and height
        var dx: Double = 0
        var dy: Double = 0
        var scale: Double = 1
    }

    var size: Double = 1
    var opacity: Double = 1
    var haptics = true
    var placements: [Group: Placement] = [:]

    subscript(group: Group) -> Placement {
        get { placements[group] ?? Placement() }
        set { placements[group] = newValue }
    }

    static let sizes = 0.6...1.5
    static let opacities = 0.3...2.0
    static let groupScales = 0.6...1.6

    private static func key(_ gameID: String?) -> String { gameID.map { "touchLayout.\($0)" } ?? "touchLayout" }

    private static func stored(_ gameID: String?) -> TouchLayout? {
        UserDefaults.standard.data(forKey: key(gameID)).flatMap { try? JSONDecoder().decode(TouchLayout.self, from: $0) }
    }

    /// A game's own layout, else the one for all games.
    static func load(for gameID: String?) -> TouchLayout {
        gameID.flatMap(stored) ?? stored(nil) ?? TouchLayout()
    }

    static func hasOwn(_ gameID: String) -> Bool { stored(gameID) != nil }

    static func save(_ layout: TouchLayout, for gameID: String?) {
        if let data = try? JSONEncoder().encode(layout) { UserDefaults.standard.set(data, forKey: key(gameID)) }
    }

    static func removeOwn(_ gameID: String) { UserDefaults.standard.removeObject(forKey: key(gameID)) }
}

/// DualShock 3 buttons, as the core takes them (rpcs3_ios_pad_button in rpcs3_ios.h).
struct PadButtons: OptionSet, Hashable {
    let rawValue: UInt32
    static let cross = PadButtons(rawValue: 1 << 0)
    static let circle = PadButtons(rawValue: 1 << 1)
    static let square = PadButtons(rawValue: 1 << 2)
    static let triangle = PadButtons(rawValue: 1 << 3)
    static let l1 = PadButtons(rawValue: 1 << 4)
    static let r1 = PadButtons(rawValue: 1 << 5)
    static let l3 = PadButtons(rawValue: 1 << 6)
    static let r3 = PadButtons(rawValue: 1 << 7)
    static let select = PadButtons(rawValue: 1 << 8)
    static let start = PadButtons(rawValue: 1 << 9)
    static let ps = PadButtons(rawValue: 1 << 10)
    static let up = PadButtons(rawValue: 1 << 11)
    static let down = PadButtons(rawValue: 1 << 12)
    static let left = PadButtons(rawValue: 1 << 13)
    static let right = PadButtons(rawValue: 1 << 14)
}

/// One controller's state, sticks from -1 to 1 with +y up, triggers from 0 to 1.
struct PadState: Equatable {
    var buttons: PadButtons = []
    var l2 = 0.0, r2 = 0.0
    var leftX = 0.0, leftY = 0.0, rightX = 0.0, rightY = 0.0
}

/// Player 1 as the game sees it: the on-screen controller and any physical controller
/// (PlayStation, Xbox, MFi) combined. Buttons from either count; a stick or trigger takes
/// whichever source is pushed further. Read once per display frame while a game runs.
@MainActor
final class PadBridge {
    static let shared = PadBridge()

    /// The on-screen controller's state, and whether it is showing.
    var touch = PadState()
    var touchVisible = true

    private var link: CADisplayLink?
    private var lastSent: PadState?

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: DisplayLinkTarget { [weak self] in self?.publish() }, selector: #selector(DisplayLinkTarget.tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        lastSent = nil
        core_set_pad(nil)
    }

    /// Whether a physical controller with sticks is connected.
    var hasPhysicalController: Bool {
        GCController.controllers().contains { $0.extendedGamepad != nil }
    }

    private var physical: PadState? {
        guard let pad = GCController.controllers().lazy.compactMap({ $0.extendedGamepad }).first else { return nil }
        var state = PadState()
        // By position: south is Cross, east Circle, west Square, north Triangle.
        let map: [(GCControllerButtonInput?, PadButtons)] = [
            (pad.buttonA, .cross), (pad.buttonB, .circle), (pad.buttonX, .square), (pad.buttonY, .triangle),
            (pad.leftShoulder, .l1), (pad.rightShoulder, .r1),
            (pad.leftThumbstickButton, .l3), (pad.rightThumbstickButton, .r3),
            (pad.buttonMenu, .start), (pad.buttonOptions, .select), (pad.buttonHome, .ps),
            (pad.dpad.up, .up), (pad.dpad.down, .down), (pad.dpad.left, .left), (pad.dpad.right, .right),
        ]
        for (button, bit) in map where button?.isPressed == true { state.buttons.insert(bit) }
        state.l2 = Double(pad.leftTrigger.value)
        state.r2 = Double(pad.rightTrigger.value)
        state.leftX = Double(pad.leftThumbstick.xAxis.value)
        state.leftY = Double(pad.leftThumbstick.yAxis.value)
        state.rightX = Double(pad.rightThumbstick.xAxis.value)
        state.rightY = Double(pad.rightThumbstick.yAxis.value)
        return state
    }

    func publish() {
        var merged = physical ?? PadState()
        if touchVisible {
            merged.buttons.formUnion(touch.buttons)
            merged.l2 = max(merged.l2, touch.l2)
            merged.r2 = max(merged.r2, touch.r2)
            if hypot(touch.leftX, touch.leftY) > hypot(merged.leftX, merged.leftY) {
                merged.leftX = touch.leftX; merged.leftY = touch.leftY
            }
            if hypot(touch.rightX, touch.rightY) > hypot(merged.rightX, merged.rightY) {
                merged.rightX = touch.rightX; merged.rightY = touch.rightY
            }
        }
        guard merged != lastSent else { return }
        lastSent = merged

        var state = core_pad()
        state.buttons = merged.buttons.rawValue
        state.lx = Float(merged.leftX); state.ly = Float(merged.leftY)
        state.rx = Float(merged.rightX); state.ry = Float(merged.rightY)
        state.l2 = Float(merged.l2); state.r2 = Float(merged.r2)
        core_set_pad(&state)
    }
}

/// CADisplayLink retains its target; this small object breaks the cycle.
private final class DisplayLinkTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func tick() { MainActor.assumeIsolated { action() } }
}

/// A PlayStation-style controller over the game, in landscape. While it is showing, every
/// touch goes to it.
///
///                          [Select] [PS] [Start]
///
///      left half: left stick                right half: right stick
///      (starts where the thumb lands)
///              L2                                       R2
///         L1                                                 R1
///                                                              △
///       ▢                                                    □   ○
///     ▢   ▢                                                    ✕
///       ▢
///
/// L1/L2 are ring segments wrapped around the D-pad, centred on the 15° and 50° lines out from
/// its centre; R1/R2 the same (mirrored) around the face buttons.
///
/// The sticks are never drawn and give no feedback: a thumb landing anywhere on the left
/// half becomes the left stick centred on that spot, and the right half the right stick. The
/// face buttons and the D-pad are bare outlines in the bottom corners, with the shoulders and
/// triggers as faint labels around them. Double-tap a stick and keep holding for L3/R3.
final class TouchControllerView: UIView {
    private enum Control: Hashable {
        case button(PadButtons)
        case l2, r2
        case leftStick, rightStick
    }

    private struct Pad {
        let control: Control
        let label: String
        var center = CGPoint.zero
        var size = CGSize.zero
        var round = true
        let view = UILabel()
        /// Shoulders and triggers: a segment of a ring around their cluster, drawn by `shape`.
        var arc: Arc?
        let shape = CAShapeLayer()
    }

    /// A ring segment: radii from `center`, and its middle angle and half width in radians
    /// (UIKit angles, clockwise from +x since y points down).
    private struct Arc {
        var center: CGPoint
        var inner: CGFloat, outer: CGFloat
        var mid: CGFloat, half: CGFloat

        var path: CGPath {
            let path = UIBezierPath(arcCenter: center, radius: outer, startAngle: mid - half, endAngle: mid + half, clockwise: true)
            path.addArc(withCenter: center, radius: inner, startAngle: mid + half, endAngle: mid - half, clockwise: false)
            path.close()
            return path.cgPath
        }

        var labelCenter: CGPoint {
            let r = (inner + outer) / 2
            return CGPoint(x: center.x + cos(mid) * r, y: center.y + sin(mid) * r)
        }

        /// With a margin around it, as thumbs land imprecisely.
        func contains(_ point: CGPoint, margin: CGFloat) -> Bool {
            let dx = point.x - center.x, dy = point.y - center.y
            let r = hypot(dx, dy)
            guard r >= inner - margin, r <= outer + margin else { return false }
            var delta = atan2(dy, dx) - mid
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            return abs(delta) <= half + margin / max(r, 1)
        }
    }

    private var pads: [Pad] = []
    /// Where each held stick's thumb is now, kept within stickRadius of its origin.
    private var stickPositions: [Control: CGPoint] = [:]
    private var stickRadius: CGFloat = 56

    /// Which control each finger holds, and where a stick's finger started.
    private var holds: [ObjectIdentifier: Control] = [:]
    private var stickOrigins: [Control: CGPoint] = [:]
    private var lastStickRelease: [Control: (time: TimeInterval, at: CGPoint)] = [:]
    private var clicked: Set<Control> = []

    private let haptics = UIImpactFeedbackGenerator(style: .light)
    private static let deadZone = 0.12

    var layout = TouchLayout() {
        didSet {
            guard layout != oldValue else { return }
            setNeedsLayout()
            resetAlpha()
        }
    }

    /// Editing the layout: a finger drags a group and two pinch it, instead of playing.
    var isEditing = false {
        didSet {
            guard isEditing != oldValue else { return }
            releaseAll()
            pinch.isEnabled = isEditing
            outlines.values.forEach { $0.isHidden = !isEditing }
            setNeedsLayout()
        }
    }

    /// Called while editing, with the changed layout.
    var onLayoutChange: ((TouchLayout) -> Void)?

    private var outlines: [TouchLayout.Group: CAShapeLayer] = [:]
    private var drags: [ObjectIdentifier: (group: TouchLayout.Group, start: CGPoint, placement: TouchLayout.Placement)] = [:]
    private var pinched: (group: TouchLayout.Group, scale: Double)?
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        let buttons: [(Control, String)] = [
            (.button(.cross), "✕"), (.button(.circle), "○"), (.button(.square), "□"), (.button(.triangle), "△"),
            (.button(.up), "▲"), (.button(.down), "▼"), (.button(.left), "◀"), (.button(.right), "▶"),
            (.button(.l1), "L1"), (.button(.r1), "R1"),
            (.l2, "L2"), (.r2, "R2"),
            (.button(.select), "SELECT"), (.button(.start), "START"), (.button(.ps), "PS"),
        ]
        for (control, label) in buttons {
            var pad = Pad(control: control, label: label)
            // Face buttons and the D-pad are bare outlines, placed where a controller has
            // them; the shoulders, triggers and Select/Start/PS keep a small faint label.
            let kind = Self.kind(of: control)
            pad.view.text = kind == .face || kind == .dpad ? nil : label
            pad.view.textAlignment = .center
            pad.view.textColor = .white
            pad.view.adjustsFontSizeToFitWidth = true
            pad.view.minimumScaleFactor = 0.6
            pad.view.layer.borderColor = UIColor.white.cgColor
            pad.view.layer.borderWidth = kind == .shoulder ? 0 : 2
            pad.view.backgroundColor = .clear
            pad.view.clipsToBounds = true
            pad.view.alpha = Self.idleAlpha(of: kind) // layout.opacity applies in resetAlpha
            pad.view.isAccessibilityElement = true
            pad.view.accessibilityLabel = label
            if kind == .shoulder {
                pad.shape.strokeColor = UIColor.white.cgColor
                pad.shape.fillColor = UIColor.clear.cgColor
                pad.shape.lineWidth = 1.5
                pad.shape.lineJoin = .round
                pad.shape.opacity = Float(Self.idleAlpha(of: kind))
                layer.addSublayer(pad.shape)
            }
            addSubview(pad.view)
            pads.append(pad)
        }
        for group in TouchLayout.Group.allCases {
            let outline = CAShapeLayer()
            outline.strokeColor = UIColor.systemYellow.cgColor
            outline.fillColor = UIColor.systemYellow.withAlphaComponent(0.08).cgColor
            outline.lineWidth = 1.5
            outline.lineDashPattern = [6, 4]
            outline.isHidden = true
            layer.addSublayer(outline)
            outlines[group] = outline
        }
        pinch.isEnabled = false
        addGestureRecognizer(pinch)
    }

    private static func group(of control: Control) -> TouchLayout.Group? {
        switch kind(of: control) {
        case .face: .face
        case .dpad: .dpad
        case .shoulder: control == .r2 || control == .button(.r1) ? .face : .dpad
        case .system: control == .leftStick || control == .rightStick ? nil : .system
        }
    }

    private func idleAlpha(of control: Control) -> CGFloat {
        min(1, max(0.05, Self.idleAlpha(of: Self.kind(of: control)) * CGFloat(layout.opacity)))
    }

    private func resetAlpha() {
        for pad in pads {
            pad.view.alpha = idleAlpha(of: pad.control)
            pad.shape.opacity = Float(idleAlpha(of: pad.control))
        }
    }

    private enum Kind { case face, dpad, shoulder, system }

    private static func kind(of control: Control) -> Kind {
        switch control {
        case .button(.cross), .button(.circle), .button(.square), .button(.triangle): .face
        case .button(.up), .button(.down), .button(.left), .button(.right): .dpad
        case .l2, .r2, .button(.l1), .button(.r1): .shoulder
        default: .system
        }
    }

    private static func idleAlpha(of kind: Kind) -> CGFloat {
        switch kind {
        case .face, .dpad: 0.45
        case .shoulder: 0.28
        case .system: 0.4
        }
    }

    required init?(coder: NSCoder) {
        fatalError("TouchControllerView is only created in code")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The phone's own edges, not the safe area: in landscape that leaves about 60
        // points unused on each side, the black bars beside a 16:9 game. The corners are
        // rounded (about 55 points), which the offsets below keep clear of.
        let area = bounds.insetBy(dx: 8, dy: 6)
        guard area.width > 0, area.height > 0 else { return }
        // Sized for a 6.9-inch phone in landscape (about 400 points of usable height);
        // smaller screens scale down so nothing overlaps.
        let base: CGFloat = min(1.1, max(0.7, min(area.height, area.width / 2) / 420)) * CGFloat(layout.size)
        // Each group's own size and place (TouchLayout), on top of the screen's
        func scale(_ group: TouchLayout.Group) -> CGFloat { base * CGFloat(layout[group].scale) }
        func offset(_ group: TouchLayout.Group) -> CGPoint {
            CGPoint(x: CGFloat(layout[group].dx) * bounds.width, y: CGFloat(layout[group].dy) * bounds.height)
        }
        let fs = scale(.face), ds = scale(.dpad), ss = scale(.system)
        // Face buttons 1.2 times, the D-pad 1.6 times their original size.
        let face = 27.6 * fs, faceGap = 51.6 * fs, arm = 54.4 * ds, dpadKey = 48 * ds
        stickRadius = 56 * base

        // Offsets from each bottom corner; the left side mirrors the right.
        let faceCenter = CGPoint(x: area.maxX - 84 * fs + offset(.face).x, y: area.maxY - 84 * fs + offset(.face).y)
        let dpad = CGPoint(x: area.minX + 84 * ds + offset(.dpad).x, y: area.maxY - 84 * ds + offset(.dpad).y)
        let top = CGPoint(x: area.midX + offset(.system).x, y: area.minY + 20 * ss + offset(.system).y)

        // Shoulders and triggers wrap around their cluster as ring segments, centred on the 15°
        // (L1/R1) and 50° (L2/R2) lines from its centre, towards the middle of the screen.
        func ring(_ center: CGPoint, degrees: CGFloat, towardsLeft: Bool, scale s: CGFloat) -> Arc {
            let up = degrees * .pi / 180
            return Arc(center: center, inner: 90 * s, outer: 124 * s,
                       mid: towardsLeft ? up - .pi : -up, half: 16 * .pi / 180)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for index in pads.indices {
            var pad = pads[index]
            switch pad.control {
            case .button(.cross): pad.center = CGPoint(x: faceCenter.x, y: faceCenter.y + faceGap)
            case .button(.circle): pad.center = CGPoint(x: faceCenter.x + faceGap, y: faceCenter.y)
            case .button(.square): pad.center = CGPoint(x: faceCenter.x - faceGap, y: faceCenter.y)
            case .button(.triangle): pad.center = CGPoint(x: faceCenter.x, y: faceCenter.y - faceGap)
            case .button(.up): pad.center = CGPoint(x: dpad.x, y: dpad.y - arm)
            case .button(.down): pad.center = CGPoint(x: dpad.x, y: dpad.y + arm)
            case .button(.left): pad.center = CGPoint(x: dpad.x - arm, y: dpad.y)
            case .button(.right): pad.center = CGPoint(x: dpad.x + arm, y: dpad.y)
            // Triggers on the steeper line, above the shoulders as on a controller.
            case .r2: pad.arc = ring(faceCenter, degrees: 50, towardsLeft: true, scale: fs)
            case .button(.r1): pad.arc = ring(faceCenter, degrees: 15, towardsLeft: true, scale: fs)
            case .l2: pad.arc = ring(dpad, degrees: 50, towardsLeft: false, scale: ds)
            case .button(.l1): pad.arc = ring(dpad, degrees: 15, towardsLeft: false, scale: ds)
            // Top centre, as on the controller.
            case .button(.select): pad.center = CGPoint(x: top.x - 70 * ss, y: top.y)
            case .button(.ps): pad.center = top
            case .button(.start): pad.center = CGPoint(x: top.x + 70 * ss, y: top.y)
            default: break
            }
            let s: CGFloat = Self.group(of: pad.control).map { scale($0) } ?? base
            switch pad.control {
            case .button(.up), .button(.down), .button(.left), .button(.right):
                pad.size = CGSize(width: dpadKey, height: dpadKey); pad.round = false
            case .l2, .r2, .button(.l1), .button(.r1):
                // The label only; the drawn shape is the ring segment
                pad.size = CGSize(width: 34 * s, height: 22 * s)
            case .button(.select), .button(.start):
                pad.size = CGSize(width: 56 * s, height: 26 * s)
            case .button(.ps):
                pad.size = CGSize(width: 34 * s, height: 34 * s)
            default:
                pad.size = CGSize(width: face * 2, height: face * 2)
            }
            if let arc = pad.arc {
                pad.center = arc.labelCenter
                pad.shape.frame = bounds
                pad.shape.path = arc.path
            }
            pad.view.frame = CGRect(x: pad.center.x - pad.size.width / 2, y: pad.center.y - pad.size.height / 2,
                                    width: pad.size.width, height: pad.size.height)
            pad.view.layer.cornerRadius = pad.round ? pad.size.height / 2 : 9 * s
            pad.view.font = .systemFont(ofSize: (Self.kind(of: pad.control) == .system ? 13 : 15) * s, weight: .semibold)
            if pad.control == .button(.ps) {
                // Apple's SF Symbol for the PlayStation logo, which may be used to refer to PlayStation
                let config = UIImage.SymbolConfiguration(pointSize: 17 * s, weight: .semibold)
                if let logo = UIImage(systemName: "playstation.logo", withConfiguration: config)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                    pad.view.attributedText = NSAttributedString(attachment: NSTextAttachment(image: logo))
                }
            }
            pads[index] = pad
        }

        // While editing: each group's outline
        if isEditing {
            for group in TouchLayout.Group.allCases {
                outlines[group]?.frame = bounds
                outlines[group]?.path = UIBezierPath(roundedRect: frame(of: group).insetBy(dx: -6, dy: -6), cornerRadius: 10).cgPath
                outlines[group]?.lineWidth = pinched?.group == group || drags.values.contains { $0.group == group } ? 2.5 : 1.5
            }
        }
    }

    /// The area a group covers, its ring segments included.
    private func frame(of group: TouchLayout.Group) -> CGRect {
        pads.filter { Self.group(of: $0.control) == group }
            .map { $0.arc.map { UIBezierPath(cgPath: $0.path).bounds } ?? $0.view.frame }
            .reduce(CGRect.null) { $0.union($1) }
    }

    private func group(at point: CGPoint) -> TouchLayout.Group? {
        TouchLayout.Group.allCases.first { frame(of: $0).insetBy(dx: -16, dy: -16).contains(point) }
    }

    // MARK: Editing

    private func editBegan(_ finger: ObjectIdentifier, at point: CGPoint) {
        guard let group = group(at: point) else { return }
        drags[finger] = (group, point, layout[group])
        setNeedsLayout()
    }

    private func editMoved(_ finger: ObjectIdentifier, to point: CGPoint) {
        guard let drag = drags[finger], bounds.width > 0, bounds.height > 0 else { return }
        var placement = drag.placement
        placement.dx = min(0.6, max(-0.6, placement.dx + Double((point.x - drag.start.x) / bounds.width)))
        placement.dy = min(0.6, max(-0.6, placement.dy + Double((point.y - drag.start.y) / bounds.height)))
        layout[drag.group] = placement
        onLayoutChange?(layout)
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            // A pinch is two fingers: no drag meanwhile
            drags.removeAll()
            if let group = group(at: gesture.location(in: self)) { pinched = (group, layout[group].scale) }
        case .changed:
            guard let pinched else { return }
            layout[pinched.group].scale = min(TouchLayout.groupScales.upperBound, max(TouchLayout.groupScales.lowerBound, pinched.scale * Double(gesture.scale)))
            onLayoutChange?(layout)
        default:
            pinched = nil
            setNeedsLayout()
        }
    }

    // MARK: Touches

    /// A slightly larger target than drawn, as thumbs land imprecisely. Anywhere else is
    /// the stick for that half of the screen.
    private func control(at point: CGPoint) -> Control {
        for pad in pads {
            if let arc = pad.arc {
                if arc.contains(point, margin: 8) { return pad.control }
                continue
            }
            let target = CGRect(origin: .zero, size: pad.size).insetBy(dx: -8, dy: -8)
                .offsetBy(dx: pad.center.x - pad.size.width / 2, dy: pad.center.y - pad.size.height / 2)
            if target.contains(point) { return pad.control }
        }
        return point.x < bounds.midX ? .leftStick : .rightStick
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isEditing {
            for touch in touches where pinched == nil { editBegan(ObjectIdentifier(touch), at: touch.location(in: self)) }
            return
        }
        for touch in touches { fingerDown(ObjectIdentifier(touch), at: touch.location(in: self), time: touch.timestamp) }
        update()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isEditing {
            for touch in touches { editMoved(ObjectIdentifier(touch), to: touch.location(in: self)) }
            return
        }
        for touch in touches { fingerMoved(ObjectIdentifier(touch), to: touch.location(in: self)) }
        update()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isEditing {
            for touch in touches { drags[ObjectIdentifier(touch)] = nil }
            setNeedsLayout()
            return
        }
        for touch in touches { fingerUp(ObjectIdentifier(touch), at: touch.location(in: self), time: touch.timestamp) }
        update()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    private func fingerDown(_ finger: ObjectIdentifier, at point: CGPoint, time: TimeInterval) {
        let control = control(at: point)
        guard !holds.values.contains(control) else { return }
        holds[finger] = control
        switch control {
        case .leftStick, .rightStick:
            // Floating: the stick's centre is where the thumb landed, so no first push is
            // lost to travel.
            stickOrigins[control] = point
            if let last = lastStickRelease[control], time - last.time < 0.3,
               hypot(point.x - last.at.x, point.y - last.at.y) < stickRadius * 1.5 {
                clicked.insert(control)
            }
            stickPositions[control] = point
        default:
            if layout.haptics { haptics.impactOccurred() }
        }
        setActive(control, true)
    }

    private func fingerMoved(_ finger: ObjectIdentifier, to point: CGPoint) {
        guard let control = holds[finger], let origin = stickOrigins[control] else { return }
        var dx = point.x - origin.x, dy = point.y - origin.y
        let length = hypot(dx, dy)
        if length > stickRadius { dx *= stickRadius / length; dy *= stickRadius / length }
        stickPositions[control] = CGPoint(x: origin.x + dx, y: origin.y + dy)
    }

    private func fingerUp(_ finger: ObjectIdentifier, at point: CGPoint, time: TimeInterval) {
        guard let control = holds.removeValue(forKey: finger) else { return }
        if control == .leftStick || control == .rightStick {
            lastStickRelease[control] = (time, point)
            stickOrigins[control] = nil
            stickPositions[control] = nil
            clicked.remove(control)
        }
        setActive(control, false)
    }

    /// Lets go of everything, for when the controller is hidden mid-press.
    func releaseAll() {
        for control in Set(holds.values) { setActive(control, false) }
        holds.removeAll()
        stickOrigins.removeAll()
        stickPositions.removeAll()
        clicked.removeAll()
        update()
    }

    private func setActive(_ control: Control, _ active: Bool) {
        switch control {
        // The sticks are never drawn.
        case .leftStick, .rightStick: break
        default:
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            for pad in pads where pad.control == control {
                let alpha = active ? max(0.9, idleAlpha(of: control)) : idleAlpha(of: control)
                pad.view.alpha = alpha
                if pad.arc != nil {
                    pad.shape.opacity = Float(alpha)
                    pad.shape.fillColor = active ? UIColor.white.withAlphaComponent(0.3).cgColor : UIColor.clear.cgColor
                } else {
                    pad.view.backgroundColor = active ? UIColor.white.withAlphaComponent(0.3) : .clear
                }
            }
        }
    }

    /// The pad state from what each finger holds.
    private func update() {
        var state = PadState()
        for control in holds.values {
            switch control {
            case .button(let bit): state.buttons.insert(bit)
            case .l2: state.l2 = 1
            case .r2: state.r2 = 1
            case .leftStick, .rightStick:
                let origin = stickOrigins[control] ?? .zero
                let knob = stickPositions[control] ?? origin
                let (x, y) = Self.shaped(dx: (knob.x - origin.x) / stickRadius, dy: (origin.y - knob.y) / stickRadius)
                if control == .leftStick {
                    state.leftX = x; state.leftY = y
                    if clicked.contains(control) { state.buttons.insert(.l3) }
                } else {
                    state.rightX = x; state.rightY = y
                    if clicked.contains(control) { state.buttons.insert(.r3) }
                }
            }
        }
        PadBridge.shared.touch = state
        PadBridge.shared.publish()
    }

    /// A radial dead zone, so a resting thumb does not drift, with the rest of the
    /// travel rescaled to the full range.
    private static func shaped(dx: Double, dy: Double) -> (Double, Double) {
        let length = hypot(dx, dy)
        guard length > deadZone else { return (0, 0) }
        let scaled = min(1, (length - deadZone) / (1 - deadZone))
        return (dx / length * scaled, dy / length * scaled)
    }
}

// SPDX-License-Identifier: MIT
import CoreGraphics

struct ScrollAxis: Equatable {
    var lines: Int64
    var fixed: Double
    var points: Int64
    var negated: Self { Self(lines: -lines, fixed: -fixed, points: -points) }
}
enum ScrollTransform {
    static func apply(vertical: ScrollAxis, horizontal: ScrollAxis, reverse: Bool, continuous: Bool)
        -> (vertical: ScrollAxis, horizontal: ScrollAxis) {
        reverse && !continuous ? (vertical.negated, horizontal.negated) : (vertical, horizontal)
    }
}
final class MouseEngine {
    private let config: Locked<AppConfig>
    init(config: Locked<AppConfig>) { self.config = config }
    func handle(type: CGEventType, event: CGEvent, proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        if type == .scrollWheel, config.get().mouse.reverseScroll,
           event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 {
            for (line, fixed, point): (CGEventField, CGEventField, CGEventField) in [
                (.scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1),
                (.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2)
            ] {
                event.setIntegerValueField(line, value: -event.getIntegerValueField(line))
                event.setDoubleValueField(fixed, value: -event.getDoubleValueField(fixed))
                event.setIntegerValueField(point, value: -event.getIntegerValueField(point))
            }
        }
        return Unmanaged.passUnretained(event)
    }
}

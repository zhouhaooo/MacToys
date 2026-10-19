// SPDX-License-Identifier: MIT
import AppKit

enum StatusItemIcon {
    // SVG coordinates use a top-left origin. Share the silhouette between the
    // filled badge and its clearance so the two stay aligned at every scale.
    private static let leafBody = "M17 5.1C17.7 9.6 16.4 14.8 12.2 15.2C10.9 15.4 9.8 15.1 9 14.6C6.2 9.5 11 8.2 14.2 7.4C15.3 7.1 16.3 6.1 17 5.1Z"
    private static let leafStem = "M6.7 16.4Q7.9 15.6 9 14.6"
    private static let leafVein = "M9.05 14.25C10.2 12.25 12.35 11 14.55 9.1C13.25 11.55 11.05 12.45 9.05 14.25Z"
    private static let leaf = makeLeafImage(clearance: false)
    private static let leafClearance = makeLeafImage(clearance: true)
    private static let idle = makeImage(isActive: false)
    private static let awake = makeImage(isActive: true)

    static func image(isActive: Bool) -> NSImage { isActive ? awake : idle }

    private static func makeImage(isActive: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let command = NSImage(systemSymbolName: "command", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            // Keep one left-leaning outline behind the solid Command card.
            let back = card(center: NSPoint(x: 7.7, y: 10.2), angle: 14)
            let front = card(center: NSPoint(x: 9, y: 9.2), angle: 0)
            back.lineWidth = 1
            back.stroke()
            NSColor.black.setFill()
            front.fill()
            front.lineWidth = 1
            front.stroke()
            command?.draw(in: NSRect(x: 5.1, y: 5.3, width: 7.8, height: 7.8),
                          from: .zero, operation: .destinationOut, fraction: 1)

            if isActive {
                let rect = NSRect(origin: .zero, size: size)
                leafClearance.draw(in: rect, from: .zero, operation: .destinationOut, fraction: 1)
                leaf.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MacToys"
        return image
    }

    private static func card(center: NSPoint, angle: CGFloat) -> NSBezierPath {
        let path = NSBezierPath(roundedRect: NSRect(x: -6, y: -6, width: 12, height: 12), xRadius: 1.8, yRadius: 1.8)
        var placement = AffineTransform()
        placement.translate(x: center.x, y: center.y)
        placement.rotate(byDegrees: angle)
        path.transform(using: placement)
        return path
    }

    private static func makeLeafImage(clearance: Bool) -> NSImage {
        let silhouette = """
        <path d="\(leafBody)" fill="black"/>
        <path d="\(leafStem)" fill="none" stroke="black" stroke-width="1.2" stroke-linecap="round"/>
        """
        let content: String
        if clearance {
            // A one-point transparent halo separates the badge from the cards.
            content = """
            <g stroke="black" stroke-width="2" stroke-linejoin="round">\(silhouette)</g>
            <path d="\(leafStem)" fill="none" stroke="black" stroke-width="3.2" stroke-linecap="round"/>
            """
        } else {
            // Cut the vein through the template alpha; it stays legible in both
            // light and dark menu bars without baking a background color in.
            content = """
            <path d="\(leafBody)\(leafVein)" fill="black" fill-rule="evenodd"/>
            <path d="\(leafStem)" fill="none" stroke="black" stroke-width="1.2" stroke-linecap="round"/>
            """
        }
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18">
        \(content)
        </svg>
        """
        // AppKit retains its SVG representation for resolution-independent drawing.
        guard let image = NSImage(data: Data(svg.utf8)) else {
            preconditionFailure("Invalid keep-awake leaf SVG")
        }
        return image
    }
}

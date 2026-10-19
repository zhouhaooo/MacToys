import SwiftUI
import AppKit

struct MacToysIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 220, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.22, green: 0.25, blue: 0.75), Color(red: 0.08, green: 0.11, blue: 0.38)], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 76).fill(.white.opacity(0.15))
                .frame(width: 520, height: 520).rotationEffect(.degrees(-14)).offset(x: -45, y: -42)
            RoundedRectangle(cornerRadius: 76).fill(.white)
                .frame(width: 520, height: 520)
                .shadow(color: .black.opacity(0.2), radius: 24, y: 20)
            Image(systemName: "command").font(.system(size: 310, weight: .medium))
                .foregroundStyle(Color(red: 0.22, green: 0.25, blue: 0.75))
        }.padding(40).frame(width: 1024, height: 1024)
    }
}
@MainActor func renderIcon() throws {
    let output = CommandLine.arguments[1]
    let renderer = ImageRenderer(content: MacToysIcon())
    renderer.scale = 1
    let rep = NSBitmapImageRep(cgImage: renderer.cgImage!)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
}
try MainActor.assumeIsolated { try renderIcon() }

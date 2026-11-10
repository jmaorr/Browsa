// The reel's closing lockup, rendered offline frame by frame with SwiftUI: Browsa's own liquid
// metal shader (Welcome/Orb.metal, twinMetal) grows from two points and fills the frame, settles
// back to a glow behind the icon, and the tagline arrives line by line.
//
//   xcrun -sdk macosx metal -c Mac/Sources/Welcome/Orb.metal -o DerivedData/metal/orb.air
//   xcrun -sdk macosx metallib DerivedData/metal/orb.air -o DerivedData/metal/orb.metallib
//   swiftc -O -parse-as-library tools/reel/lockup.swift -o DerivedData/reel-lockup
//   DerivedData/reel-lockup <orb.metallib> <out dir> [width height fps seconds]

import SwiftUI
import AppKit

func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
func phase(_ t: Double, _ s: Double, _ l: Double) -> Double { clamp((t - s) / l) }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 3) }
func easeInOut(_ x: Double) -> Double { -(cos(.pi * clamp(x)) - 1) / 2 }

struct Lockup: View {
    let t: Double
    let library: ShaderLibrary
    let icon: NSImage
    let size: CGSize

    // The stage's own graphite, so the metal grows out of the background the acts sit on.
    let base = SIMD3<Float>(0.06, 0.06, 0.07)

    var body: some View {
        // Metal fills, holds a beat in full colour, then sinks to a low glow behind the type.
        let metal = 1 - 0.62 * easeInOut(phase(t, 2.4, 1.6))
        ZStack {
            Color(red: 0.03, green: 0.03, blue: 0.035)
            Rectangle()
                .colorEffect(library.twinMetal(.float2(size), .float(t * 0.9), .float3(base.x, base.y, base.z), .float(0.22)))
                .opacity(metal)
                .scaleEffect(1 + 0.04 * t / 8)
            // A soft dark well so the type always reads.
            RadialGradient(colors: [.black.opacity(0.8 * phase(t, 2.6, 1.4)), .clear], center: .center,
                           startRadius: 0, endRadius: size.width * 0.5)
            VStack(spacing: size.height * 0.035) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: size.height * 0.2, height: size.height * 0.2)
                    .shadow(color: .black.opacity(0.5), radius: size.height * 0.03, y: size.height * 0.012)
                    .modifier(Arrive(p: phase(t, 3.0, 1.1), size: size))
                VStack(spacing: size.height * 0.006) {
                    line("Beautiful browsing.", at: 3.7)
                    line("Incredible power.", at: 4.3)
                    line("Built for Mac.", at: 4.9)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func line(_ s: String, at start: Double) -> some View {
        Text(s)
            .font(.system(size: size.height * 0.068, weight: .semibold))
            .tracking(-size.height * 0.0022)
            .foregroundStyle(.white)
            .modifier(Arrive(p: phase(t, start, 0.9), size: size))
    }
}

/// Blurs in and rises a touch, the way Apple's titles arrive.
struct Arrive: ViewModifier {
    let p: Double
    let size: CGSize
    func body(content: Content) -> some View {
        let e = easeOut(p)
        content
            .opacity(e)
            .blur(radius: (1 - e) * size.height * 0.02)
            .offset(y: (1 - e) * size.height * 0.02)
    }
}

/// A title card between acts (REEL_CARD="Incredible power."): the line arrives on the dark stage
/// and leaves the same way.
struct Card: View {
    let t: Double, seconds: Double, text: String, size: CGSize
    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(red: 0.105, green: 0.108, blue: 0.125), Color(red: 0.02, green: 0.02, blue: 0.025)],
                           center: .init(x: 0.5, y: 0.45), startRadius: 0, endRadius: size.width * 0.7)
            Text(text)
                .font(.system(size: size.height * 0.085, weight: .semibold))
                .tracking(-size.height * 0.003)
                .foregroundStyle(.white)
                .modifier(Arrive(p: phase(t, 0.15, 0.9) - phase(t, seconds - 0.7, 0.6), size: size))
        }
        .frame(width: size.width, height: size.height)
    }
}

/// A feature title beside the window (REEL_TITLE="Radar|Keeping your localhosts organised."),
/// on a clear background, for laying over a staged beat. REEL_TITLE_OUT=0 keeps it to the end.
struct FeatureTitle: View {
    let t: Double, seconds: Double, title: String, line: String, size: CGSize, leaves: Bool
    var body: some View {
        let out = leaves ? phase(t, seconds - 0.7, 0.6) : 0
        VStack(alignment: .leading, spacing: size.height * 0.018) {
            Text(title)
                .font(.system(size: size.height * 0.074, weight: .semibold))
                .tracking(-size.height * 0.0025)
                .foregroundStyle(.white)
                .modifier(Arrive(p: phase(t, 0.25, 0.9) - out, size: size))
            Text(line)
                .font(.system(size: size.height * 0.03, weight: .regular))
                .foregroundStyle(.white.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
                .modifier(Arrive(p: phase(t, 0.55, 0.9) - out, size: size))
        }
        .frame(width: size.width * 0.27, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, size.width * 0.065)
        .frame(width: size.width, height: size.height)
    }
}

@main
struct Main {
    @MainActor static func main() throws {
        let a = CommandLine.arguments
        let library = ShaderLibrary(url: URL(fileURLWithPath: a[1]))
        let out = URL(fileURLWithPath: a[2])
        let w = a.count > 3 ? Double(a[3])! : 1920, h = a.count > 4 ? Double(a[4])! : 1080
        let fps = a.count > 5 ? Double(a[5])! : 60, seconds = a.count > 6 ? Double(a[6])! : 7
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let iconPath = ProcessInfo.processInfo.environment["REEL_ICON"] ?? NSHomeDirectory() + "/Applications/Browsa.app"
        let icon = NSWorkspace.shared.icon(forFile: iconPath)
        icon.size = NSSize(width: 1024, height: 1024)
        let stills = ProcessInfo.processInfo.environment["REEL_STILLS"].map { $0.split(separator: ",").map { Double($0)! } }
        let todo = stills.map { $0.map { Int($0 * fps) } } ?? Array(0..<Int(seconds * fps))
        for i in todo {
            let t = Double(i) / fps
            let size = CGSize(width: w, height: h)
            let card = ProcessInfo.processInfo.environment["REEL_CARD"]
            let feature = ProcessInfo.processInfo.environment["REEL_TITLE"].map { $0.split(separator: "|").map(String.init) }
            let leaves = ProcessInfo.processInfo.environment["REEL_TITLE_OUT"] != "0"
            let r = feature.map { ImageRenderer(content: AnyView(FeatureTitle(t: t, seconds: seconds, title: $0[0], line: $0.count > 1 ? $0[1] : "", size: size, leaves: leaves))) }
                ?? card.map { ImageRenderer(content: AnyView(Card(t: t, seconds: seconds, text: $0, size: size))) }
                ?? ImageRenderer(content: AnyView(Lockup(t: t, library: library, icon: icon, size: size)))
            r.scale = 2
            guard let cg = r.cgImage else { print("no image at \(i)"); continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            try rep.representation(using: .png, properties: [:])!.write(to: out.appending(path: String(format: "f%05d.png", i)))
            if i % 60 == 0 { print("frame \(i)") }
        }
        print("done")
    }
}

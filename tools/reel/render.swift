// The reel renderer: lays Browsa's real UI layers out in 3D with SceneKit and renders a scene
// frame by frame, deterministically, so every take is identical and any resolution works.
//
//   swiftc -O tools/reel/render.swift -o DerivedData/reel-render
//   DerivedData/reel-render <layers dir> <out dir> [width height fps seconds]
//
// Layers come from tools/reel/layers.py (layers.json gives each one's frame in window points).

import AppKit
import SceneKit

// MARK: - Easing

func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
func smooth(_ x: Double) -> Double { let c = clamp(x); return c * c * (3 - 2 * c) }
func easeOutCubic(_ x: Double) -> Double { let c = clamp(x); return 1 - pow(1 - c, 3) }
func easeInOutQuint(_ x: Double) -> Double { let c = clamp(x); return c < 0.5 ? 16 * pow(c, 5) : 1 - pow(-2 * c + 2, 5) / 2 }
/// A settle with the faintest overshoot, like a sheet of glass landing.
func land(_ x: Double) -> Double {
    let c = clamp(x)
    let s = 1.25
    return 1 + (s + 1) * pow(c - 1, 3) + s * pow(c - 1, 2)
}
func easeOutQuint(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 5) }
func easeInOutCubic(_ x: Double) -> Double { let c = clamp(x); return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2 }
func easeOutSine(_ x: Double) -> Double { sin(.pi / 2 * clamp(x)) }
func easeInOutSine(_ x: Double) -> Double { -(cos(.pi * clamp(x)) - 1) / 2 }
func phase(_ t: Double, _ start: Double, _ length: Double) -> Double { clamp((t - start) / length) }
func mix(_ a: Double, _ b: Double, _ f: Double) -> Double { a + (b - a) * f }

// MARK: - Layers

struct Meta: Decodable {
    let window: [Double]
    let layers: [String: [Double]]
}

let args = CommandLine.arguments
let layersDir = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
let width = args.count > 3 ? Int(args[3])! : 1920
let height = args.count > 4 ? Int(args[4])! : 1080
let fps = args.count > 5 ? Double(args[5])! : 60
let seconds = args.count > 6 ? Double(args[6])! : 12
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: layersDir.appending(path: "layers.json")))
let winW = meta.window[0], winH = meta.window[1]

let scene = SCNScene()
let stage = SCNNode()          // the window's own space: x right, y up, z out of the glass
scene.rootNode.addChildNode(stage)

/// Filtering that holds up at steep angles: trilinear mipmaps and full anisotropy, so edges and
/// type stay clean instead of shimmering and stair-stepping as the planes tilt away.
/// Layers never depth-test against each other: they sit a point or two apart, and depth tests at
/// that spacing flicker (layers vanishing and popping back). They draw in stacking order instead,
/// and still write depth so the depth of field knows how far away each one is.
func sharp(_ m: SCNMaterial) {
    m.diffuse.mipFilter = .linear
    m.diffuse.minificationFilter = .linear
    m.diffuse.magnificationFilter = .linear
    m.diffuse.maxAnisotropy = 16
    m.readsFromDepthBuffer = false
    m.writesToDepthBuffer = true
}

/// Draw order, back to front.
let stack = ["window", "card", "bottom", "address", "fav0", "fav1", "fav2", "fav3",
             "newtab", "tab0", "tab1", "tab2", "tab3", "tab4", "tab5"]

/// A layer as a plane at its place in the window, in points, centred on the window.
/// `from` a second layer set (the space swiped to) names the node "b:<name>" and draws it just
/// above its twin.
func plane(_ name: String, from dir: URL? = nil) -> SCNNode {
    let f = meta.layers[name]!
    let image = NSImage(contentsOf: (dir ?? layersDir).appending(path: "\(name).png"))!
    let geo = SCNPlane(width: f[2], height: f[3])
    let m = SCNMaterial()
    m.diffuse.contents = image
    // Constant: the UI's own pixels, exactly. Depth comes from the shadow cards under each layer.
    m.lightingModel = .constant
    m.isDoubleSided = false
    m.transparencyMode = .aOne
    sharp(m)
    geo.materials = [m]
    let node = SCNNode(geometry: geo)
    node.name = dir == nil ? name : "b:" + name
    node.castsShadow = false
    node.renderingOrder = 10 * (stack.firstIndex(of: name) ?? 0) + (dir == nil ? 0 : 2)
    // Window points (top-left origin) to stage (centre origin, y up).
    node.position = SCNVector3(f[0] + f[2] / 2 - winW / 2, winH / 2 - (f[1] + f[3] / 2), 0)
    stage.addChildNode(node)
    return node
}

/// A soft shadow image: a blurred rounded rect, made once per size.
func shadowImage(width: Double, height: Double, radius: Double, blur: Double) -> NSImage {
    let pad = blur * 3
    let size = NSSize(width: width + pad * 2, height: height + pad * 2)
    let img = NSImage(size: size)
    img.lockFocus()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 1)
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: -10000)
    shadow.set()
    NSColor.black.setFill()
    NSBezierPath(roundedRect: NSRect(x: pad, y: pad + 10000, width: width, height: height), xRadius: radius, yRadius: radius).fill()
    img.unlockFocus()
    return img
}

/// A shadow card on the glass under a layer: soft and faint while the layer is high, tightening as it lands.
var shadows: [String: SCNNode] = [:]
func addShadow(for name: String, radius: Double, blur: Double = 18) {
    let f = meta.layers[name]!
    let img = shadowImage(width: f[2], height: f[3], radius: radius, blur: blur)
    let geo = SCNPlane(width: img.size.width, height: img.size.height)
    let m = SCNMaterial()
    m.diffuse.contents = img
    m.lightingModel = .constant
    m.writesToDepthBuffer = false
    m.readsFromDepthBuffer = false
    geo.materials = [m]
    let n = SCNNode(geometry: geo)
    n.renderingOrder = 10 * (stack.firstIndex(of: name) ?? 0) - 5
    n.position = SCNVector3(f[0] + f[2] / 2 - winW / 2, winH / 2 - (f[1] + f[3] / 2) - 6, 0.1)
    stage.addChildNode(n)
    shadows[name] = n
}

let window = plane("window")
let card = plane("card")
let address = plane("address")
let favs = (0..<4).map { plane("fav\($0)") }
let newTab = plane("newtab")
let tabs = (0..<6).map { plane("tab\($0)") }
let bottom = plane("bottom")

// The space swiped to at the end (REEL_B: its layer dir). The favourites are shared across spaces.
let bDir = ProcessInfo.processInfo.environment["REEL_B"].map { URL(fileURLWithPath: $0) }
let swapNames = ["window", "card", "bottom", "address", "newtab"] + (0..<6).map { "tab\($0)" }
let bNodes: [String: SCNNode] = bDir.map { d in Dictionary(uniqueKeysWithValues: swapNames.map { ($0, plane($0, from: d)) }) } ?? [:]
for n in bNodes.values { n.opacity = 0 }
for (k, n) in bNodes where k != "window" { n.isHidden = true }

/// A region that slides from one space's picture to the next's, clipped to its own frame: redrawn
/// each frame as one image, so nothing ever shows outside it.
final class SwipePanel {
    let node: SCNNode
    let a: CGImage, b: CGImage
    let size: CGSize
    let radius: CGFloat
    init(_ name: String, a: URL, b: URL, radius: CGFloat, order: Int, z: Double) {
        func load(_ u: URL) -> CGImage { NSImage(contentsOf: u)!.cgImage(forProposedRect: nil, context: nil, hints: nil)! }
        self.a = load(a.appending(path: "\(name).png"))
        self.b = load(b.appending(path: "\(name).png"))
        size = CGSize(width: self.a.width, height: self.a.height)
        self.radius = radius
        let f = meta.layers[name]!
        let geo = SCNPlane(width: f[2], height: f[3])
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.transparencyMode = .aOne
        sharp(m)
        geo.materials = [m]
        node = SCNNode(geometry: geo)
        node.renderingOrder = order
        node.name = "panel:" + name
        node.position = SCNVector3(f[0] + f[2] / 2 - winW / 2, winH / 2 - (f[1] + f[3] / 2), z)
        node.isHidden = true
        stage.addChildNode(node)
    }
    /// f = 0: all the first space; 1: all the next.
    func show(_ f: Double) {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let r = CGRect(origin: .zero, size: size)
        if radius > 0 { ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.clip() }
        let x = size.width * f
        ctx.draw(a, in: r.offsetBy(dx: -x, dy: 0))
        ctx.draw(b, in: r.offsetBy(dx: size.width - x, dy: 0))
        node.geometry!.firstMaterial!.diffuse.contents = ctx.makeImage()
    }
}
let panels: (side: SwipePanel, page: SwipePanel)? = bDir.map { d in
    (SwipePanel("sidebar", a: layersDir, b: d, radius: 0, order: 10 * stack.firstIndex(of: "address")! - 4, z: 1.5),
     SwipePanel("card", a: layersDir, b: d, radius: 40, order: 10 * stack.firstIndex(of: "card")! + 1, z: 3))
}

/// Each layer's resting height above the glass, in points.
var rest: [String: Double] = ["window": 0, "card": 3, "address": 1.5, "newtab": 1, "bottom": 1,
                               "fav0": 2, "fav1": 2, "fav2": 2, "fav3": 2, "tab0": 1.5, "tab1": 1.5, "tab2": 1.5, "tab3": 1.5, "tab4": 1.5, "tab5": 1.5]
for (k, v) in rest { rest["b:" + k] = v }
let home = Dictionary(uniqueKeysWithValues: stage.childNodes.map { ($0.name!, $0.position) })
addShadow(for: "window", radius: 22, blur: 40)
addShadow(for: "card", radius: 18, blur: 22)
for n in ["address", "fav0", "fav1", "fav2", "fav3"] { addShadow(for: n, radius: 10, blur: 10) }
shadows["window"]!.position.z = -2

// The address bar's carve: a soft dark inset that deepens under it as it sinks in.
let carve: SCNNode = {
    let f = meta.layers["address"]!
    let geo = SCNPlane(width: f[2] + 6, height: f[3] + 6)
    geo.cornerRadius = 9
    let m = SCNMaterial()
    m.diffuse.contents = NSColor.black
    m.lightingModel = .constant
    m.transparency = 0
    m.readsFromDepthBuffer = false
    geo.materials = [m]
    let n = SCNNode(geometry: geo)
    n.renderingOrder = 10 * stack.firstIndex(of: "address")! - 3
    n.position = home["address"]!
    n.position.z = 0.6
    stage.addChildNode(n)
    return n
}()

// MARK: - Light and camera

// A dark stage (REEL_STAGE=light for the old one): deep graphite with a soft lift in the middle,
// so the window sits in a pool of light, and it meets the dark liquid metal reveal.
scene.background.contents = {
    if ProcessInfo.processInfo.environment["REEL_STAGE"] == "light" {
        return NSColor(calibratedRed: 0.93, green: 0.92, blue: 0.94, alpha: 1) as Any
    }
    let size = NSSize(width: 1600, height: 900)
    let img = NSImage(size: size)
    img.lockFocus()
    NSGradient(colors: [NSColor(calibratedRed: 0.105, green: 0.108, blue: 0.125, alpha: 1),
                        NSColor(calibratedRed: 0.045, green: 0.045, blue: 0.055, alpha: 1),
                        NSColor(calibratedRed: 0.02, green: 0.02, blue: 0.025, alpha: 1)],
               atLocations: [0, 0.6, 1], colorSpace: .sRGB)!
        .draw(in: NSRect(origin: .zero, size: size), relativeCenterPosition: NSPoint(x: 0, y: 0.1))
    img.unlockFocus()
    return img as Any
}()

// A light sweep: a soft white streak that crosses the address bar as it carves in.
let sweep: SCNNode = {
    let w = 90.0, h = Double(meta.layers["address"]![3]) - 4
    let img = NSImage(size: NSSize(width: w, height: h))
    img.lockFocus()
    NSGradient(colors: [NSColor(white: 1, alpha: 0), NSColor(white: 1, alpha: 0.55), NSColor(white: 1, alpha: 0)])!
        .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: 0)
    img.unlockFocus()
    let geo = SCNPlane(width: w, height: h)
    let m = SCNMaterial()
    m.diffuse.contents = img
    m.lightingModel = .constant
    m.blendMode = .add
    m.writesToDepthBuffer = false
    m.readsFromDepthBuffer = false
    geo.materials = [m]
    let n = SCNNode(geometry: geo)
    n.renderingOrder = 10 * stack.firstIndex(of: "address")! + 3
    n.opacity = 0
    stage.addChildNode(n)
    return n
}()

let camera = SCNCamera()
camera.zNear = 1
camera.zFar = 20000
camera.fieldOfView = 30
camera.wantsDepthOfField = true
camera.fStop = 2.8
camera.focalBlurSampleCount = 12
camera.apertureBladeCount = 9
camera.wantsHDR = false
let cameraNode = SCNNode()
cameraNode.camera = camera
scene.rootNode.addChildNode(cameraNode)

/// Places the camera looking at `target` (stage points) from `distance`, at a pitch and yaw.
func aim(at target: SCNVector3, distance: Double, pitch: Double, yaw: Double, roll: Double = 0) {
    let world = stage.convertPosition(target, to: nil)
    let x = world.x + distance * sin(yaw) * cos(pitch)
    let y = world.y - distance * sin(pitch)
    let z = world.z + distance * cos(yaw) * cos(pitch)
    cameraNode.position = SCNVector3(x, y, z)
    cameraNode.look(at: world, up: SCNVector3(sin(roll), cos(roll), 0), localFront: SCNVector3(0, 0, -1))
    camera.focusDistance = distance
}

// MARK: - Act 1: the window assembles

/// Places every layer for time t. Layers fall from above the glass onto it, one after another.
func act1(_ t: Double) {
    // One continuous move over the whole shot: the slab rights itself and the camera pulls back,
    // never stopping and never snapping.
    let whole = easeInOutSine(t / seconds)
    stage.eulerAngles = SCNVector3(mix(-1.0, -0.08, easeOutSine(t / 6.0)), 0, 0)

    // Layers lower onto the glass and settle: a long ease-out, no overshoot.
    func drop(_ node: SCNNode, at start: Double, length: Double = 1.8, height: Double = 120) {
        let f = phase(t, start, length)
        let p = home[node.name!]!
        node.position = SCNVector3(p.x, p.y, (rest[node.name!] ?? 0) + height * (1 - easeOutQuint(f)))
        node.opacity = smooth(f / 0.2)
    }

    drop(window, at: 0.0, length: 2.4, height: 220)
    drop(card, at: 0.5, length: 2.4, height: 90)
    drop(bottom, at: 1.0)

    // The address bar lowers in and sinks just into the surface; the carve deepens under it.
    let a = phase(t, 1.4, 1.8)
    let ap = home["address"]!
    address.position = SCNVector3(ap.x, ap.y, 1.5 + 50 * (1 - easeOutQuint(a)))
    address.opacity = smooth(a / 0.15)
    carve.geometry!.firstMaterial!.transparency = 0.18 * smooth(phase(t, 1.9, 1.0))
    let sw = phase(t, 1.9, 1.5)
    let half = Double(meta.layers["address"]![2]) / 2 - 45
    sweep.opacity = 0   // the light sweep read as a cheap shimmer; the bar just settles in
    sweep.position = SCNVector3(Double(ap.x) - half + 2 * half * easeInOutSine(sw), Double(ap.y), 3)

    for (i, f) in favs.enumerated() { drop(f, at: 2.3 + Double(i) * 0.14, length: 1.5, height: 60) }

    // Tabs glide in from the left, one after another.
    for (i, n) in ([newTab] + tabs).enumerated() {
        let f = phase(t, 2.9 + Double(i) * 0.12, 1.5)
        let p = home[n.name!]!
        n.position = SCNVector3(p.x - 120 * (1 - easeOutQuint(f)), p.y, rest[n.name!] ?? 1)
        n.opacity = smooth(f / 0.3)
    }

    // A beat after everything lands, a swipe to the next space, as Browsa does it: the sidebar
    // slides across as one piece (the favourites stay, they're in every space) and the page slides
    // with it, the new space's following in from the right.
    let swipeAt = seconds - 2.2
    if let panels {
        let f = easeInOutCubic(phase(t, swipeAt, 0.75))
        let on = t >= swipeAt
        for n in [address, newTab, bottom, carve] + tabs { n.isHidden = on }
        panels.side.node.isHidden = !on
        panels.page.node.isHidden = !on
        card.isHidden = on
        if on {
            panels.side.show(f)
            panels.page.show(f)
            bNodes["window"]!.opacity = smooth(phase(t, swipeAt, 0.75))
            sweep.opacity = 0
        }
    }

    // Shadows: faint and wide while a layer is high, tight once it lands.
    for (name, sh) in shadows {
        guard let n = stage.childNode(withName: name, recursively: false) else { continue }
        let h = Double(n.position.z) - (rest[name] ?? 0)
        let k = clamp(h / 200)
        let shown = name == "card" || name == "window" ? 1 : n.opacity
        sh.opacity = (name == "window" || name == "card" ? 1 : n.opacity) * (name == "window" ? 0.35 : 0.22) * (1 - 0.7 * k) * shown
        sh.scale = SCNVector3(1 + 0.25 * k, 1 + 0.25 * k, 1)
    }

    // Camera: low over the window's top corner, pulling back the whole time to the full window.
    let target = SCNVector3(mix(-560, 30, whole), mix(330, -20, whole), 0)
    aim(at: target, distance: mix(620, 2050, whole), pitch: mix(0.10, 0.0, whole), yaw: mix(-0.14, 0.0, whole))
    camera.fStop = mix(1.8, 5.6, whole)
}

// MARK: - Render

let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
renderer.scene = scene
renderer.pointOfView = cameraNode
let frames = Int(seconds * fps)
// Rendered at 2x and scaled down by ffmpeg: supersampling on top of MSAA keeps thin edges clean.
let ss = Double(ProcessInfo.processInfo.environment["REEL_SS"] ?? "2")!
// REEL_STILLS="0,2.5,6" renders just those seconds, for checking the look.
let stills = ProcessInfo.processInfo.environment["REEL_STILLS"].map { $0.split(separator: ",").map { Double($0)! } }
let todo: [Int] = stills.map { $0.map { Int($0 * fps) } } ?? Array(0..<frames)
for i in todo {
    let t = Double(i) / fps
    act1(t)
    let image = renderer.snapshot(atTime: t, with: CGSize(width: Double(width) * ss, height: Double(height) * ss), antialiasingMode: .multisampling4X)
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try png.write(to: outDir.appending(path: String(format: "f%05d.png", i)))
    if i % 120 == 0 { print("frame \(i)/\(frames)") }
}
print("done")

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
// Small layers get a wide, faint shadow: soft and gentle, never a hard rim.
for n in ["address", "fav0", "fav1", "fav2", "fav3"] { addShadow(for: n, radius: 14, blur: 26) }
shadows["window"]!.position.z = -2

// A soft glow round the window's edge in the liquid metal's colours, so the frame never sits
// stale on black: bright as it lands, settling to a faint halo.
let frameGlow: SCNNode = {
    let w = winW + 260, h = winH + 260
    let img = NSImage(size: NSSize(width: w, height: h))
    img.lockFocus()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 110
    shadow.shadowOffset = NSSize(width: 0, height: -10000)
    let rect = NSRect(x: 130, y: 130 + 10000, width: winW, height: winH)
    for (col, dx, dy) in [(NSColor(srgbRed: 1.0, green: 0.45, blue: 0.18, alpha: 0.9), -40.0, 30.0),
                          (NSColor(srgbRed: 0.98, green: 0.25, blue: 0.35, alpha: 0.7), 40.0, -30.0),
                          (NSColor(srgbRed: 0.55, green: 0.85, blue: 0.35, alpha: 0.35), 0.0, 0.0)] {
        shadow.shadowColor = col; shadow.shadowOffset = NSSize(width: dx, height: dy - 10000)
        NSGraphicsContext.saveGraphicsState(); shadow.set()
        NSColor.black.setFill(); NSBezierPath(roundedRect: rect, xRadius: 23, yRadius: 23).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    img.unlockFocus()
    let geo = SCNPlane(width: w, height: h)
    let m = SCNMaterial(); m.diffuse.contents = img; m.lightingModel = .constant
    m.blendMode = .add; m.writesToDepthBuffer = false; m.readsFromDepthBuffer = false
    geo.materials = [m]
    let n = SCNNode(geometry: geo)
    n.renderingOrder = -20
    n.position = SCNVector3(0, 0, -3)
    stage.addChildNode(n)
    return n
}()

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
    frameGlow.position.z = window.position.z - 3
    frameGlow.opacity = window.opacity * (0.12 + 0.3 * (1 - smooth(phase(t, 1.0, 3.5))))
    drop(card, at: 0.5, length: 2.4, height: 90)
    drop(bottom, at: 1.0)

    // The address bar lowers in and sinks just into the surface; the carve deepens under it.
    let a = phase(t, 1.4, 1.8)
    let ap = home["address"]!
    address.position = SCNVector3(ap.x, ap.y, 1.5 + 50 * (1 - easeOutQuint(a)))
    address.opacity = smooth(a / 0.15)
    carve.isHidden = true   // the dark inset read as a clipped, hard shadow
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
        let strength = name == "window" ? 0.35 : name == "card" ? 0.22 : 0.12
        sh.opacity = (name == "window" || name == "card" ? 1 : n.opacity) * strength * (1 - 0.7 * k) * shown
        sh.scale = SCNVector3(1 + 0.25 * k, 1 + 0.25 * k, 1)
    }

    // Camera: low over the window's top corner, pulling back the whole time to the full window.
    let target = SCNVector3(mix(-560, 30, whole), mix(330, -20, whole), 0)
    aim(at: target, distance: mix(620, 2050, whole), pitch: mix(0.10, 0.0, whole), yaw: mix(-0.14, 0.0, whole))
    camera.fStop = mix(1.8, 5.6, whole)
}

// MARK: - Act 2: the real app, recorded, on the same stage

/// REEL_ACT=2 with REEL_FRAMES=<dir of s00001.jpg…>: a recording of the live window (ScreenCaptureKit)
/// played on the window's plane, with the window's own corners as its mask, and the camera moving
/// in to follow each edit. REEL_KEYS="t:x:y:distance,…" sets the camera path (window points).
let act = Int(ProcessInfo.processInfo.environment["REEL_ACT"] ?? "1")!
let framesDir = ProcessInfo.processInfo.environment["REEL_FRAMES"].map { URL(fileURLWithPath: $0) }
let screen: SCNNode? = act == 2 ? {
    let f = meta.layers["window"]!
    let geo = SCNPlane(width: f[2], height: f[3])
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.transparencyMode = .aOne
    // The window's alpha (rounded corners, edge) as the mask over the recording's square frames.
    m.transparent.contents = NSImage(contentsOf: (bDir ?? layersDir).appending(path: "window.png"))
    sharp(m)
    m.transparent.mipFilter = .linear
    geo.materials = [m]
    let n = SCNNode(geometry: geo)
    n.name = "screen"
    n.renderingOrder = 1
    stage.addChildNode(n)
    return n
}() : nil
let keys: [(t: Double, x: Double, y: Double, d: Double)] = (ProcessInfo.processInfo.environment["REEL_KEYS"] ?? "0:30:-20:2050")
    .split(separator: ",").map { k in let v = k.split(separator: ":").map { Double($0)! }; return (v[0], v[1], v[2], v[3]) }

// MARK: Cursor: animated over the recording, so its motion is smooth and it can hand over from
// your Mac cursor to the agent's amber pointer. REEL_CURSOR="t:x:y:kind:click;…" in window points,
// kind m (Mac) or a (agent), click 1 for a ring at that key.

struct CursorKey { let t: Double, x: Double, y: Double, agent: Bool, click: Bool }
let cursorKeys: [CursorKey] = (ProcessInfo.processInfo.environment["REEL_CURSOR"] ?? "").split(separator: ";").compactMap { k in
    let v = k.split(separator: ":")
    guard v.count >= 4 else { return nil }
    return CursorKey(t: Double(v[0])!, x: Double(v[1])!, y: Double(v[2])!, agent: v[3] == "a", click: v.count > 4 && v[4] == "1")
}

func spritePlane(_ img: NSImage, width: Double, order: Int) -> SCNNode {
    let geo = SCNPlane(width: width, height: width * img.size.height / img.size.width)
    let m = SCNMaterial()
    m.diffuse.contents = img
    m.lightingModel = .constant
    m.transparencyMode = .aOne
    sharp(m)
    m.writesToDepthBuffer = false
    geo.materials = [m]
    let n = SCNNode(geometry: geo)
    n.renderingOrder = order
    n.isHidden = true
    stage.addChildNode(n)
    return n
}

/// macOS's own arrow, and Browsa's agent pointer (pointer.arrow.ipad in the agents' amber).
let macCursorImage: NSImage = {
    // The classic arrow, drawn as vectors (NSCursor's image needs a running app): black with a
    // white keyline and a soft shadow, at 4x.
    let k = 4.0, pad = 3.0
    let pts: [(Double, Double)] = [(0, 0), (0, 17), (4.2, 13.1), (7, 19.6), (9.4, 18.6), (6.7, 12.3), (12, 12.3)]
    let size = NSSize(width: (14 + pad * 2) * k, height: (22 + pad * 2) * k)
    let img = NSImage(size: size)
    img.lockFocus()
    let path = NSBezierPath()
    for (i, p) in pts.enumerated() {
        let q = NSPoint(x: (p.0 + pad) * k, y: size.height - (p.1 + pad) * k)
        i == 0 ? path.move(to: q) : path.line(to: q)
    }
    path.close()
    path.lineJoinStyle = .round
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.4); shadow.shadowBlurRadius = 2.5 * k; shadow.shadowOffset = NSSize(width: 0, height: -1 * k)
    NSGraphicsContext.saveGraphicsState(); shadow.set()
    NSColor.white.setStroke(); path.lineWidth = 1.6 * k; path.stroke()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.setStroke(); path.lineWidth = 1.6 * k; path.stroke()
    NSColor.black.setFill(); path.fill()
    img.unlockFocus()
    return img
}()
let agentCursorImage: NSImage = {
    let amber = NSColor(red: 0.96, green: 0.71, blue: 0.04, alpha: 1)
    let config = NSImage.SymbolConfiguration(pointSize: 64, weight: .regular).applying(.init(paletteColors: [amber]))
    let sym = NSImage(systemSymbolName: "pointer.arrow.ipad", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    let pad = 14.0
    let img = NSImage(size: NSSize(width: sym.size.width + pad * 2, height: sym.size.height + pad * 2))
    img.lockFocus()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.45); shadow.shadowBlurRadius = 6; shadow.shadowOffset = NSSize(width: 0, height: -3)
    shadow.set()
    sym.draw(in: NSRect(x: pad, y: pad, width: sym.size.width, height: sym.size.height))
    img.unlockFocus()
    return img
}()
let ringImage: NSImage = {
    let img = NSImage(size: NSSize(width: 200, height: 200))
    img.lockFocus()
    NSColor.white.withAlphaComponent(0.9).setStroke()
    let p = NSBezierPath(ovalIn: NSRect(x: 12, y: 12, width: 176, height: 176)); p.lineWidth = 10; p.stroke()
    img.unlockFocus()
    return img
}()
let macCursor = spritePlane(macCursorImage, width: 22, order: 9000)
let agentCursor = spritePlane(agentCursorImage, width: 30, order: 9001)
let ring = spritePlane(ringImage, width: 40, order: 8999)

/// Window points (top-left origin) to stage, a little above the glass.
func stagePoint(_ x: Double, _ y: Double, z: Double = 4) -> SCNVector3 { SCNVector3(x - winW / 2, winH / 2 - y, z) }

func placeCursor(_ t: Double) {
    guard let first = cursorKeys.first else { return }
    var a = first, b = first
    for k in cursorKeys where k.t <= t { a = k }
    b = cursorKeys.first { $0.t > t } ?? a
    let f = b.t > a.t ? easeInOutCubic((t - a.t) / (b.t - a.t)) : 0
    let x = mix(a.x, b.x, f), y = mix(a.y, b.y, f)
    // Agent-ness eases over a third of a second around the key where it changes.
    let switchKey = cursorKeys.first { $0.agent } 
    let agentMix = switchKey.map { smooth((t - $0.t + 0.15) / 0.35) } ?? 0
    let visible = smooth((t - first.t) / 0.3)
    // Each sprite's hotspot is its top-left tip.
    // Mac arrow: its tip sits pad (3 of 20 units) in from the top-left.
    let mw = 22.0, mh = mw * macCursorImage.size.height / macCursorImage.size.width
    macCursor.position = stagePoint(x + mw / 2 - mw * 3 / 20, y + mh / 2 - mh * 3 / 28)
    macCursor.opacity = visible * (1 - agentMix)
    macCursor.isHidden = false
    let aw = 30.0, ah = aw * agentCursorImage.size.height / agentCursorImage.size.width
    agentCursor.position = stagePoint(x + aw * 0.36, y + ah * 0.32, z: 4.2)
    let pop = 1 + 0.35 * sin(.pi * clamp(agentMix)) 
    agentCursor.scale = SCNVector3(pop, pop, 1)
    agentCursor.opacity = visible * agentMix
    agentCursor.isHidden = false
    // Click ring: the last click key within the past half second.
    if let c = cursorKeys.last(where: { $0.click && $0.t <= t && t - $0.t < 0.5 }) {
        let p = (t - c.t) / 0.5
        ring.isHidden = false
        ring.position = stagePoint(c.x, c.y, z: 3.8)
        let s = 0.4 + 1.2 * easeOutCubic(p)
        ring.scale = SCNVector3(s, s, 1)
        ring.opacity = 0.8 * (1 - p)
        ring.geometry!.firstMaterial!.diffuse.contents = ringImage
    } else { ring.isHidden = true }
}

// A second cursor (REEL_CURSOR2, same key format, always the agent's pointer): a collaborator
// arriving while your own cursor is still on screen.
let cursorKeys2: [CursorKey] = (ProcessInfo.processInfo.environment["REEL_CURSOR2"] ?? "").split(separator: ";").compactMap { k in
    let v = k.split(separator: ":")
    guard v.count >= 3 else { return nil }
    return CursorKey(t: Double(v[0])!, x: Double(v[1])!, y: Double(v[2])!, agent: true, click: v.count > 4 && v[4] == "1")
}
let agentCursor2 = spritePlane(agentCursorImage, width: 30, order: 9002)

func placeCursor2(_ t: Double) {
    guard let first = cursorKeys2.first, t >= first.t - 0.01 else { agentCursor2.isHidden = true; return }
    var a = first
    for k in cursorKeys2 where k.t <= t { a = k }
    let b = cursorKeys2.first { $0.t > t } ?? a
    let f = b.t > a.t ? easeInOutCubic((t - a.t) / (b.t - a.t)) : 0
    let x = mix(a.x, b.x, f), y = mix(a.y, b.y, f)
    let aw = 30.0, ah = aw * agentCursorImage.size.height / agentCursorImage.size.width
    agentCursor2.isHidden = false
    agentCursor2.position = stagePoint(x + aw * 0.36, y + ah * 0.32, z: 4.3)
    // Arrives with a little pop.
    let p = clamp((t - first.t) / 0.4)
    let pop = 0.6 + 0.4 * easeOutCubic(p) + 0.18 * sin(.pi * p)
    agentCursor2.scale = SCNVector3(pop, pop, 1)
    agentCursor2.opacity = smooth(p)
}

// Hand-animated pieces over a recording: REEL_SPRITES="file@cx:cy:w:h:t0:t1:t2,…" (window points):
// the image slides down into place and fades in from t0 to t1, and stays until t2.
struct Sprite { let node: SCNNode; let cx, cy, t0, t1, t2: Double }
let sprites: [Sprite] = (ProcessInfo.processInfo.environment["REEL_SPRITES"] ?? "").split(separator: ",").compactMap { spec in
    let parts = spec.split(separator: "@")
    guard parts.count == 2, let img = NSImage(contentsOfFile: String(parts[0])) else { return nil }
    let v = parts[1].split(separator: ":").map { Double($0)! }
    let n = spritePlane(img, width: v[2], order: 8000)
    n.geometry = SCNPlane(width: v[2], height: v[3]); n.geometry!.materials = [{ let m = SCNMaterial(); m.diffuse.contents = img; m.lightingModel = .constant; sharp(m); m.writesToDepthBuffer = false; return m }()]
    return Sprite(node: n, cx: v[0], cy: v[1], t0: v[4], t1: v[5], t2: v[6])
}
func placeSprites(_ t: Double) {
    for s in sprites {
        guard t >= s.t0, t < s.t2 else { s.node.isHidden = true; continue }
        let f = easeOutCubic((t - s.t0) / (s.t1 - s.t0))
        s.node.isHidden = false
        s.node.position = stagePoint(s.cx, s.cy - 14 * (1 - f), z: 1.0)
        s.node.opacity = f
    }
}

/// REEL_LIGHTS="r,g,b" (the sidebar's colour) paints the traffic lights back over a recording:
/// while ScreenCaptureKit records, macOS swaps them for its screen-sharing pill.
let lightsOverlay: SCNNode? = ProcessInfo.processInfo.environment["REEL_LIGHTS"].map { spec in
    let c = spec.split(separator: ",").map { Double($0)! / 255 }
    let img = NSImage(size: NSSize(width: 160, height: 64))
    img.lockFocus()
    // The sidebar under the pill, with the window's own top-left corner (radius 23pt = 46px).
    NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1).setFill()
    let patch = NSBezierPath()
    patch.move(to: NSPoint(x: 0, y: 0)); patch.line(to: NSPoint(x: 160, y: 0)); patch.line(to: NSPoint(x: 160, y: 62))
    patch.line(to: NSPoint(x: 46, y: 62)); patch.appendArc(withCenter: NSPoint(x: 46, y: 16), radius: 46, startAngle: 90, endAngle: 180)
    patch.close(); patch.fill()
    for (cx, col) in [(32.0, NSColor(srgbRed: 234/255, green: 103/255, blue: 101/255, alpha: 1)),
                      (78.0, NSColor(srgbRed: 241/255, green: 202/255, blue: 61/255, alpha: 1)),
                      (124.0, NSColor(srgbRed: 105/255, green: 196/255, blue: 99/255, alpha: 1))] {
        col.setFill(); NSBezierPath(ovalIn: NSRect(x: cx - 12.5, y: 64 - 32 - 12.5, width: 25, height: 25)).fill()
    }
    img.unlockFocus()
    let n = spritePlane(img, width: 80, order: 5)
    n.isHidden = false
    n.position = stagePoint(40, 16, z: 0.5)
    return n
}

func act2(_ t: Double, frame: Int) {
    for n in stage.childNodes where n !== screen && n.name != nil { n.isHidden = true }
    frameGlow.isHidden = true
    placeCursor(t)
    placeCursor2(t)
    placeSprites(t)
    for (_, sh) in shadows { sh.isHidden = true }
    shadows["window"]?.isHidden = false
    shadows["window"]?.opacity = 0.35
    carve.isHidden = true; sweep.isHidden = true
    if let dir = framesDir {
        let url = dir.appending(path: String(format: "s%05d.jpg", frame + 1))
        if let img = NSImage(contentsOf: url) { screen!.geometry!.firstMaterial!.diffuse.contents = img }
    }
    // A fixed, gentle three-quarter turn (REEL_YAW) so the window faces the title beside it.
    let yaw = Double(ProcessInfo.processInfo.environment["REEL_YAW"] ?? "0")!
    stage.eulerAngles = SCNVector3(-0.06 + 0.02 * sin(t / seconds * .pi), yaw, 0)
    // Between camera keys, a sine ease: it leans in, holds a beat, leans out.
    var a = keys[0], b = keys[0]
    for i in keys.indices where keys[i].t <= t { a = keys[i]; b = i + 1 < keys.count ? keys[i + 1] : keys[i] }
    let f = b.t > a.t ? easeInOutSine((t - a.t) / (b.t - a.t)) : 0
    aim(at: SCNVector3(mix(a.x, b.x, f), mix(a.y, b.y, f), 0), distance: mix(a.d, b.d, f), pitch: 0, yaw: 0)
    camera.fStop = 5.6
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
    if act == 2 { act2(t, frame: i) } else { act1(t) }
    let image = renderer.snapshot(atTime: t, with: CGSize(width: Double(width) * ss, height: Double(height) * ss), antialiasingMode: .multisampling4X)
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try png.write(to: outDir.appending(path: String(format: "f%05d.png", i)))
    if i % 120 == 0 { print("frame \(i)/\(frames)") }
}
print("done")

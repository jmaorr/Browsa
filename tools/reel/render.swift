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
let stack = ["window", "lights", "card", "toolbar", "bottom", "address", "fav0", "fav1", "fav2", "fav3",
             "newtab", "tab0", "tab1", "tab2"]

/// A layer as a plane at its place in the window, in points, centred on the window.
func plane(_ name: String) -> SCNNode {
    let f = meta.layers[name]!
    let image = NSImage(contentsOf: layersDir.appending(path: "\(name).png"))!
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
    node.name = name
    node.castsShadow = false
    node.renderingOrder = 10 * (stack.firstIndex(of: name) ?? 0)
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
let lights = plane("lights")
let card = plane("card")
let toolbar = plane("toolbar")
let address = plane("address")
let favs = (0..<4).map { plane("fav\($0)") }
let newTab = plane("newtab")
let tabs = (0..<3).map { plane("tab\($0)") }
let bottom = plane("bottom")

/// Each layer's resting height above the glass, in points.
let rest: [String: Double] = ["window": 0, "lights": 0.5, "card": 3, "toolbar": 1, "address": 1.5, "newtab": 1, "bottom": 1,
                               "fav0": 2, "fav1": 2, "fav2": 2, "fav3": 2, "tab0": 1.5, "tab1": 1.5, "tab2": 1.5]
let home = Dictionary(uniqueKeysWithValues: stage.childNodes.map { ($0.name!, $0.position) })
addShadow(for: "window", radius: 22, blur: 40)
addShadow(for: "card", radius: 18, blur: 22)
for n in ["address", "fav0", "fav1", "fav2", "fav3", "tab0"] { addShadow(for: n, radius: 10, blur: 10) }
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

scene.background.contents = NSColor(calibratedRed: 0.93, green: 0.92, blue: 0.94, alpha: 1)

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
    // The window tilts back like a slab on a table, then slowly rights itself.
    let lift = smooth(phase(t, 6.5, 5.5))
    stage.eulerAngles = SCNVector3(mix(-1.05, -0.12, lift), 0, 0)

    func drop(_ node: SCNNode, at start: Double, length: Double = 1.4, height: Double = 260) {
        let f = phase(t, start, length)
        let p = home[node.name!]!
        node.position = SCNVector3(p.x, p.y, (rest[node.name!] ?? 0) + height * (1 - land(f)))
        node.opacity = smooth(f / 0.12)
    }

    drop(window, at: 0.0, length: 1.8, height: 520)
    lights.position = SCNVector3(home["lights"]!.x, home["lights"]!.y, window.position.z + 0.5)
    lights.opacity = window.opacity
    drop(card, at: 0.9, length: 1.9, height: 420)
    drop(toolbar, at: 1.5)
    drop(bottom, at: 1.7)

    // The address bar comes down glowing and sinks just into the surface; the carve deepens under it.
    let a = phase(t, 2.3, 1.6)
    let ap = home["address"]!
    address.position = SCNVector3(ap.x, ap.y, 1.5 + 70 * (1 - easeOutCubic(a)))
    address.opacity = smooth(a / 0.12)
    address.geometry!.firstMaterial!.emission.contents = NSColor(white: 1, alpha: 1)
    address.geometry!.firstMaterial!.emission.intensity = 0.5 * (1 - smooth(phase(t, 2.8, 1.4)))
    carve.geometry!.firstMaterial!.transparency = 0.12 * smooth(phase(t, 3.0, 0.9))
    let s = phase(t, 2.9, 1.5)
    // Stays within the bar: rides from its left edge to its right.
    let half = Double(meta.layers["address"]![2]) / 2 - 45
    sweep.opacity = sin(.pi * s)
    sweep.position = SCNVector3(Double(ap.x) - half + 2 * half * easeInOutQuint(s), Double(ap.y), 3)

    for (i, f) in favs.enumerated() { drop(f, at: 3.6 + Double(i) * 0.14, length: 1.0, height: 90) }

    // Tabs slide in from the left edge, staggered.
    for (i, n) in ([newTab] + tabs).enumerated() {
        let f = phase(t, 4.6 + Double(i) * 0.16, 1.1)
        let p = home[n.name!]!
        n.position = SCNVector3(p.x - 180 * (1 - easeOutCubic(f)), p.y, rest[n.name!] ?? 1)
        n.opacity = smooth(f / 0.25)
    }

    // Shadows: faint and wide while a layer is high, tight once it lands.
    for (name, sh) in shadows {
        guard let n = stage.childNode(withName: name, recursively: false) else { continue }
        let h = Double(n.position.z) - (rest[name] ?? 0)
        let k = clamp(h / 300)
        sh.opacity = n.opacity * (name == "window" ? 0.35 : 0.22) * (1 - 0.7 * k)
        sh.scale = SCNVector3(1 + 0.25 * k, 1 + 0.25 * k, 1)
    }

    // Camera: close and low over the sidebar's top, then a long dolly out to the whole window.
    let pull = easeInOutQuint(phase(t, 0, 11))
    let target = SCNVector3(mix(-560, 30, pull), mix(330, -20, pull), 0)
    // Level horizon throughout: a low, slightly-left start that straightens, never a roll.
    aim(at: target, distance: mix(620, 2000, pull), pitch: mix(0.10, 0.0, pull), yaw: mix(-0.14, 0.0, pull))
    camera.fStop = mix(1.6, 5.6, pull)
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

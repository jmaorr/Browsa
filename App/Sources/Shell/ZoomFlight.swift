import UIKit

/// The tab gallery's zoom: one picture of a page flying between the page and its card, like
/// Safari's. It's a plain image view on top of the window, positioned in window coordinates, so
/// SwiftUI's safe areas and the system's bars can't nudge it, and it's the only thing that moves.
/// The spring matches `Motion.spring`, so SwiftUI changes made alongside stay in step.
@MainActor final class ZoomFlight {
    private var view: UIImageView?
    private var animator: UIViewPropertyAnimator?

    /// Counts pictures, so a late fade-out can't take away a newer picture.
    private(set) var generation = 0

    /// The window the picture is in, while there is one.
    var window: UIWindow? { view?.window }

    /// A full-resolution picture of `view` as it is on screen.
    static func snapshot(of view: UIView) -> UIImage? {
        guard view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
    }

    /// The page's own background in a picture of it: the colour at its left edge, halfway down,
    /// clear of headers and the status bar.
    static func edgeColor(of picture: UIImage) -> CGColor? {
        guard let cg = picture.cgImage, cg.width > 4, cg.height > 4,
              let strip = cg.cropping(to: CGRect(x: 1, y: cg.height / 2, width: 2, height: 2)) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(strip, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return CGColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }

    /// Puts `picture` on top of `window` at `frame`, replacing any picture already there.
    func start(_ picture: UIImage, in window: UIWindow, at frame: CGRect, cornerRadius: CGFloat) {
        land()
        generation += 1
        let v = UIImageView(image: picture)
        // The picture has the page's shape and so does the card, so filling crops nothing.
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.layer.cornerCurve = .continuous
        v.layer.cornerRadius = cornerRadius
        v.isUserInteractionEnabled = false
        v.frame = frame
        window.addSubview(v)
        view = v
    }

    /// Flies the picture to `frame`. `alongside` runs at take-off, for SwiftUI changes that
    /// should move with it; `landed` runs once it's there.
    func fly(to frame: CGRect, cornerRadius: CGFloat, alongside: () -> Void, landed: @escaping () -> Void) {
        guard let v = view else { alongside(); landed(); return }
        let timing: UITimingCurveProvider = UIAccessibility.isReduceMotionEnabled
            ? UICubicTimingParameters(animationCurve: .easeInOut)
            : UISpringTimingParameters(mass: 1, stiffness: 320, damping: 30, initialVelocity: .zero)
        let a = UIViewPropertyAnimator(duration: 0.2, timingParameters: timing)
        a.addAnimations {
            v.frame = frame
            v.layer.cornerRadius = cornerRadius
        }
        a.addCompletion { [weak self] _ in
            self?.animator = nil
            landed()
        }
        animator = a
        alongside()
        a.startAnimation()
    }

    /// Fades the picture away, once what it stood in for is on screen underneath.
    func fadeOut(generation: Int) {
        guard generation == self.generation, let v = view else { return }
        view = nil
        UIView.animate(withDuration: 0.12, animations: { v.alpha = 0 }, completion: { _ in v.removeFromSuperview() })
    }

    /// Takes the picture away at once.
    func land() {
        animator?.stopAnimation(true)
        animator = nil
        view?.removeFromSuperview()
        view = nil
    }
}

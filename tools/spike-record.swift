// spike-record: records one window to a .mov with ScreenCaptureKit, even while other windows
// cover it, so SpikeBrowsa can be filmed without taking the screen.
// Usage: spike-record <windowID> <seconds> <out.mov> [fps]
//        spike-record shot <windowID> <out.png>   (the window plus its app's menus and popovers on top)
// Built by `tools/spikectl record`; runs under the terminal's Screen Recording permission.
import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import AppKit

let args = CommandLine.arguments
_ = NSApplication.shared  // ScreenCaptureKit needs a window-server connection.

if args.count == 4, args[1] == "shot", let windowID = UInt32(args[2]) {
    let out = URL(fileURLWithPath: args[3])
    Task {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }), let app = window.owningApplication,
                  let display = content.displays.first(where: { $0.frame.intersects(window.frame) }) else {
                FileHandle.standardError.write(Data("No window \(windowID)\n".utf8)); exit(1)
            }
            // Every on-screen window of the app (menus are their own windows), nothing else.
            let mine = content.windows.filter { $0.owningApplication?.processID == app.processID && $0.isOnScreen }
            let filter = SCContentFilter(display: display, including: mine)
            let config = SCStreamConfiguration()
            let scale = Int(filter.pointPixelScale)
            // The window, grown to take in menus that hang past its edges.
            let area = mine.reduce(window.frame) { $0.union($1.frame) }.intersection(display.frame)
            config.sourceRect = CGRect(x: area.minX - display.frame.minX, y: area.minY - display.frame.minY,
                                       width: area.width, height: area.height)
            config.width = Int(area.width) * scale
            config.height = Int(area.height) * scale
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])!.write(to: out)
            print(out.path)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1)
        }
    }
    RunLoop.main.run()
}

guard args.count >= 4, let windowID = UInt32(args[1]), let seconds = Double(args[2]) else {
    FileHandle.standardError.write(Data("usage: spike-record <windowID> <seconds> <out.mov> [fps]\n".utf8))
    exit(2)
}
let outURL = URL(fileURLWithPath: args[3])
let fps = Int32(args.count > 4 ? Int(args[4]) ?? 30 : 30)

final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    var started = false
    let queue = DispatchQueue(label: "spike-record")

    init(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: sb.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData { input.append(sb) }
    }
}

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            FileHandle.standardError.write(Data("No window \(windowID)\n".utf8)); exit(1)
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = Int(filter.pointPixelScale)
        config.width = Int(window.frame.width) * scale
        config.height = Int(window.frame.height) * scale
        config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let recorder = try Recorder(url: outURL, width: config.width, height: config.height)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
        try await stream.startCapture()
        try await Task.sleep(for: .seconds(seconds))
        try await stream.stopCapture()
        recorder.queue.sync {}
        recorder.input.markAsFinished()
        await recorder.writer.finishWriting()
        print(outURL.path)
        exit(recorder.writer.status == .completed ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}
RunLoop.main.run()

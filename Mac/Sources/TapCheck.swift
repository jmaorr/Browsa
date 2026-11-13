// SPIKE (not for commit): can Browsa tap its own WebKit GPU process's audio, and does macOS prompt?
// Runs only with BROWSA_TAP_CHECK=1. Writes ~/Library/Logs/Browsa/tap-check.log.
#if DEBUG
import CoreAudio
import Foundation
import WebKit

@MainActor enum TapCheck {
    static let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Browsa/tap-check.log")
    static func say(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: log, atomically: true, encoding: .utf8) }
    }
    static var keep: [AnyObject] = []

    static func runIfAsked() {
        guard ProcessInfo.processInfo.environment["BROWSA_TAP_CHECK"] == "1" else { return }
        // Make sure WebKit has started its GPU process: a web view with a tiny page.
        let wv = WKWebView(frame: .init(x: 0, y: 0, width: 10, height: 10))
        wv.loadHTMLString("<audio></audio>", baseURL: nil)
        keep.append(wv)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { check() }
    }

    typealias Resp = @convention(c) (pid_t) -> pid_t
    static func responsible(_ pid: pid_t) -> pid_t {
        guard let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return -1 }
        return unsafeBitCast(f, to: Resp.self)(pid)
    }

    static func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ def: T) -> T {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v = def; var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : def
    }

    static func check() {
        let me = getpid(), owner = responsible(getpid())
        say("Browsa pid \(me), responsible \(owner)")
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
        var mine: [AudioObjectID] = []
        for id in ids {
            let pid: pid_t = prop(id, kAudioProcessPropertyPID, 0)
            let r = responsible(pid)
            if r == owner && pid != me { mine.append(id); say("own process object \(id) pid \(pid)") }
        }
        guard !mine.isEmpty else { say("no audio process object found whose responsible pid is Browsa (\(me))"); return }
        let desc = CATapDescription(stereoMixdownOfProcesses: mine)
        desc.name = "Browsa call audio check"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(0)
        let st = AudioHardwareCreateProcessTap(desc, &tap)
        say("AudioHardwareCreateProcessTap status \(st) tap \(tap)")
        guard st == noErr else { return }
        let uid = desc.uuid.uuidString
        let agg: [String: Any] = [kAudioAggregateDeviceNameKey: "Browsa tap check", kAudioAggregateDeviceUIDKey: "browsa.tapcheck.\(UUID().uuidString)",
                                  kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceTapAutoStartKey: true,
                                  kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uid]]]
        var dev = AudioObjectID(0)
        let st2 = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &dev)
        say("AudioHardwareCreateAggregateDevice status \(st2) device \(dev)")
        guard st2 == noErr else { AudioHardwareDestroyProcessTap(tap); return }
        final class Box: @unchecked Sendable { var frames = 0; var peak: Float = 0 }
        let box = Box()
        var procID: AudioDeviceIOProcID?
        let st3 = AudioDeviceCreateIOProcIDWithBlock(&procID, dev, nil) { _, inData, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            for b in list { if let p = b.mData?.assumingMemoryBound(to: Float.self) { let n = Int(b.mDataByteSize) / 4; box.frames += n; for i in 0..<n { box.peak = max(box.peak, abs(p[i])) } } }
        }
        say("AudioDeviceCreateIOProcIDWithBlock status \(st3)")
        let st4 = AudioDeviceStart(dev, procID)
        say("AudioDeviceStart status \(st4)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            AudioDeviceStop(dev, procID)
            if let procID { AudioDeviceDestroyIOProcID(dev, procID) }
            AudioHardwareDestroyAggregateDevice(dev)
            AudioHardwareDestroyProcessTap(tap)
            say("read \(box.frames) samples in 3 s, peak \(box.peak) (0 = silent, expected with nothing playing)")
        }
    }
}
#endif

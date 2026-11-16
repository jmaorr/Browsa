import CoreAudio
import Foundation
// devvol.swift <device name> [new scalar 0-1]: prints a device's output volume per element, sets them if a value is
// given. Used by bench.mjs to put every output device back as it found it (compiled once into derived/audio-lab).
let name = CommandLine.arguments[1]
var size = UInt32(0)
var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
var ids = [AudioDeviceID](repeating: 0, count: Int(size) / 4)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
for id in ids {
    var n: CFString = "" as CFString; var s = UInt32(MemoryLayout<CFString>.size)
    var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(id, &a, 0, nil, &s, &n)
    guard (n as String) == name else { continue }
    for el: UInt32 in [0, 1, 2] {
        var va = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: el)
        guard AudioObjectHasProperty(id, &va) else { continue }
        var v = Float32(0); var vs = UInt32(4)
        AudioObjectGetPropertyData(id, &va, 0, nil, &vs, &v)
        print("element \(el): \(v)")
        if CommandLine.arguments.count > 2, var nv = Float32(CommandLine.arguments[2]) { AudioObjectSetPropertyData(id, &va, 0, nil, 4, &nv) }
    }
}

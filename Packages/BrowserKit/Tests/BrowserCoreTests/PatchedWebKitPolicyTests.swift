import Testing
import Foundation
@testable import BrowserCore

@Suite struct PatchedWebKitPolicyTests {
    private func decide(enabled: Bool = true, build: Bool = true, active: Bool = false, tried: Bool = false,
                        allowed: Bool = true, app: Bool = true) -> PatchedWebKitPolicy.Decision {
        PatchedWebKitPolicy.decide(enabled: enabled, buildPresent: build, active: active, alreadyTried: tried,
                                   allowedBySignature: allowed, isApp: app)
    }

    @Test func relaunchesOntoAPresentBuild() {
        #expect(decide() == .relaunch)
    }

    @Test func staysWhenAlreadyOnIt() {
        #expect(decide(active: true) == .stay(.active))
        // Even switched off: it's already running, nothing to undo until the next launch.
        #expect(decide(enabled: false, active: true) == .stay(.active))
    }

    @Test func staysOnTheSystemWebKitOtherwise() {
        #expect(decide(enabled: false) == .stay(.disabled))
        #expect(decide(build: false) == .stay(.noBuild))
        #expect(decide(allowed: false) == .stay(.notAllowed))
        #expect(decide(app: false) == .stay(.notApp))
    }

    @Test func neverLoops() {
        // Started once with the variables and still not on it: dyld ignored them. Carry on.
        #expect(decide(tried: true) == .stay(.alreadyTried))
    }

    @Test func environmentPointsBothTheAppAndWebKitsProcessesAtTheBuild() {
        let env = PatchedWebKitPolicy.environment(base: ["HOME": "/Users/x", "BROWSA_CALL_AUDIO_NS": "3"], frameworks: "/wk")
        #expect(env["DYLD_FRAMEWORK_PATH"] == "/wk")
        #expect(env["__XPC_DYLD_FRAMEWORK_PATH"] == "/wk")
        #expect(env["DYLD_LIBRARY_PATH"] == "/wk")
        #expect(env["__XPC_DYLD_LIBRARY_PATH"] == "/wk")
        #expect(env["__XPC_BROWSA_CALL_AUDIO_NS"] == "3")
        #expect(env["HOME"] == "/Users/x")
        #expect(env[PatchedWebKitPolicy.triedKey] == "1")
    }

    @Test func activeOnlyForFrameworksInsideTheFolder() {
        #expect(PatchedWebKitPolicy.isActive(loaded: "/wk/Release/WebKit.framework", frameworks: "/wk/Release"))
        #expect(PatchedWebKitPolicy.isActive(loaded: "/wk/Release/WebKit.framework", frameworks: "/wk/Release/"))
        #expect(!PatchedWebKitPolicy.isActive(loaded: "/wk/Release-meeting/WebKit.framework", frameworks: "/wk/Release"))
        #expect(!PatchedWebKitPolicy.isActive(loaded: "/System/Library/Frameworks/WebKit.framework", frameworks: "/wk/Release"))
    }
}

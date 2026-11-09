import Foundation

/// Store extensions checked end to end in Browsa: installed from the store, signed in or set up,
/// and doing their main job on real sites. The install bar and add sheet mark these "Works in
/// Browsa"; the rest say they haven't been tested. Add an id only after that full check.
public enum VerifiedExtensions {
    /// By `ExtensionSource.key`.
    static let keys: Set<String> = [
        "chrome:aeblfdkhhhdcdjpifhhbdiojplfjncoa",  // 1Password
        "chrome:hdokiejnpimakedhajhdlcegeplioahd",  // LastPass
        "chrome:fdjamakpfbbddfjaooikfcpapjohcfmg",  // Dashlane
        "chrome:kbfnbcaeplbcioakkpcpgfkobkghlhen",  // Grammarly
        "chrome:ddkjiahejlhfcafbddmgiahcphecmpfh",  // uBlock Origin Lite
        "chrome:eimadpbcbfnmbkopoojfekhnkhdbieeh",  // Dark Reader
    ]

    public static func contains(_ source: ExtensionSource) -> Bool { keys.contains(source.key) }
}

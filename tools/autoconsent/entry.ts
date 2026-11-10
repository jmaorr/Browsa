// Entry point for the cookie-banner script injected into main frames, and into the subframes
// that frame-gate.mjs's gate picks out (see build.sh).
//
// Runs DuckDuckGo's autoconsent (MPL-2.0) in an isolated content world. It finds the site's
// consent manager, clicks through to "reject all", and hides the banner meanwhile. Messages go to
// the app through the "autoconsent" script message handler; the app runs any "eval" steps in the
// page world and answers through window.autoconsentReceiveMessage.
import AutoConsent from '../../.autoconsent/package/lib/web';
import { filterCompactRules, type IndexedCMPRuleset } from '../../.autoconsent/package/lib/encoding';
import compactRules from '../../.autoconsent/package/rules/compact-rules.json';

declare global {
    interface Window {
        autoconsentReceiveMessage?: (message: unknown) => Promise<void>;
        webkit: { messageHandlers: { autoconsent: { postMessage(m: unknown): void } } };
    }
}

if (!window.autoconsentReceiveMessage) {
    // Config goes to initialize(), not the constructor: given a config, the constructor initializes
    // before it has made its DOM actions, and in WebKit (where the root element already exists at
    // document start) the prehide step then throws and autoconsent never looks for a banner.
    // Without one it sends an "init" message first, which the app ignores.
    const consent = new AutoConsent(
        async (message) => { window.webkit.messageHandlers.autoconsent.postMessage(message); },
    );
    consent.initialize(
        {
            enabled: true,
            autoAction: 'optOut',
            disabledCmps: [],
            enablePrehide: true,
            enableCosmeticRules: true,
            enableGeneratedRules: true,
            enableHeuristicDetection: true,
            enablePopupMutationObserver: false,
            detectRetries: 20,
            isMainWorld: false,
            prehideTimeout: 2000,
            visualTest: false,
            logs: { lifecycle: false, rulesteps: false, detectionsteps: false, evals: false, errors: false, messages: false, waits: false },
        },
        {
            autoconsent: [],
            compact: filterCompactRules(compactRules as IndexedCMPRuleset, {
                url: window.location.href,
                mainFrame: window.top === window,
            }),
        },
    );
    window.autoconsentReceiveMessage = (message) => consent.receiveMessageCallback(message as never);
}

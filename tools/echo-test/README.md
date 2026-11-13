# Mic and echo test

A page for comparing how browsers handle a microphone on a call, Browsa included.

Run `tools/echo-test/serve.sh`, then open http://localhost:8765 in Browsa, Safari, Arc and Chrome.
In each one: allow the microphone, pick the mic, and run the echo test with speakers at call volume
(no headphones). The page plays speech-like sound through a media element, as a call site plays
other people's voices, and measures how much of it comes back through the mic. Copy the results
table from each browser to compare.

The echo and constraint settings start as Google Meet asks for them: echo cancellation, noise
suppression and auto gain on. "Got" shows what the browser actually applied.

## Echo over a real Meet call (meet-bot)

`meet-bot/` tests the real Meet path instead of this page's loopback. A hidden Chromium joins your Meet as
the guest "Echo bot", talks by playing `standup.mp3` as its microphone (its own sound is muted, so it never
uses the speakers), and records what Browsa sends back. Any of its own voice in that is echo; it's scored
the same way as this page, in dB above the noise floor.

```sh
cd tools/echo-test/meet-bot && npm install
node bot.mjs --selftest                                   # silent local check, no Meet
node bot.mjs --url https://meet.google.com/abc-defg-hij   # your meeting, opened in Browsa
```

As of November 2026 Meet sends an automated guest to its marketing page instead of the lobby ("System info
will be sent to confirm you're not a bot"), so on Meet itself this only gets as far as the join page; `--selftest`
still checks the recording and scoring. Open meet.new in Browsa (signed in), pass its link, admit "Echo bot" when it knocks, and stay quiet while
it talks (60 s by default, `--seconds` to change). It prints Browsa's call log alongside and saves the
recording in `runs/` (left: what it sent, right: what came back). Uses Playwright's Chromium if installed,
else the Google Chrome app with a throwaway profile.

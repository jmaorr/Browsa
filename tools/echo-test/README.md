# Mic and echo test

A page for comparing how browsers handle a microphone on a call, Browsa included.

Run `tools/echo-test/serve.sh`, then open http://localhost:8765 in Browsa, Safari, Arc and Chrome.
In each one: allow the microphone, pick the mic, and run the echo test with speakers at call volume
(no headphones). The page plays speech-like sound through a media element, as a call site plays
other people's voices, and measures how much of it comes back through the mic. Copy the results
table from each browser to compare.

The echo and constraint settings start as Google Meet asks for them: echo cancellation, noise
suppression and auto gain on. "Got" shows what the browser actually applied.

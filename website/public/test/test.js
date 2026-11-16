// While the page is hidden, measure how far the audio got, so you can see on return whether the
// browser kept it playing. Also names the track for Control Centre and the Lock Screen.
const audio = document.getElementById('audio');
const video = document.getElementById('video');
const result = document.getElementById('audio-result');
let away = null;

const clock = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;

document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    away = audio.paused ? null : { at: performance.now(), from: audio.currentTime, ended: 0 };
    return;
  }
  if (!away) return;
  const gone = (performance.now() - away.at) / 1000;
  const played = Math.max(0, audio.currentTime - away.from + away.ended);
  away = null;
  if (gone < 3) return;
  const kept = played >= gone - 2;
  result.hidden = false;
  result.textContent = kept
    ? `You were away for ${clock(gone)} and the audio played the whole time. Background audio works in this browser.`
    : `You were away for ${clock(gone)} but the audio only played for ${clock(played)}. This browser stopped it in the background.`;
});

// Loop, and count a lap so the total stays right across the restart.
audio.addEventListener('ended', () => {
  if (away) { away.ended += audio.duration - away.from; away.from = 0; }
  audio.currentTime = 0;
  audio.play();
});

// One player at a time.
audio.addEventListener('play', () => video.pause());
video.addEventListener('play', () => audio.pause());

if ('mediaSession' in navigator) {
  const art = [{ src: '/favicon.png', sizes: '64x64', type: 'image/png' }];
  const name = (title) => () => {
    navigator.mediaSession.metadata = new MediaMetadata({ title, artist: 'browsa.app/test', artwork: art });
  };
  audio.addEventListener('play', name('Background audio test'));
  video.addEventListener('play', name('Picture in Picture test'));
}

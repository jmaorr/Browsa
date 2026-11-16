# What's New

Each file here is one entry on [browsa.app/whats-new](https://browsa.app/whats-new/). Wrangler
builds the page from them before every `wrangler dev` and `wrangler deploy`, so adding an entry is:

1. Copy `_template.md` to `YYYY-MM-DD-short-name.md`. The name after the date becomes the entry's
   link, like `/whats-new/#audio-engine`.
2. Put its clip in `public/media/whats-new/`: an `.mp4` (H.264, about 1600 wide, 16:10, under
   about 5 MB, no sound) and a `.webp` poster of its first frame.
3. Write the title and one or two sentences, in the release notes' words (`docs/release-notes/`).
   A second paragraph becomes the smaller note, for where to change or turn something off.
4. Leave `draft: true` until the feature has shipped. Then set the date, delete that line, and add
   the date to the front of the file name so the folder reads in order.

To see the page: `npx wrangler dev`, or `node scripts/build-whats-new.mjs --drafts` and open
`public/whats-new/index.html` through the dev server to see drafts too. Rebuild without `--drafts`
before you commit (a deploy always does).

## Fields

| Field | |
| --- | --- |
| `title` | The feature's name, as in the release notes after "New:". |
| `date` | `YYYY-MM-DD`, the day it shipped. Needed once it isn't a draft. |
| `platform` | `Mac`, `iPhone` or `Mac and iPhone`. |
| `version` | The release it came in, like `1.1`. |
| `video` | A clip under `public/`, like `/media/whats-new/audio-engine.mp4`. Short clips loop silently while on screen. |
| `loop` | `false` for a longer film with sound, which waits for its play button. |
| `poster` | The clip's still, shown before it plays and with reduced motion. |
| `image` | A still instead of a clip. |
| `scene` | Instead of a clip: the Mac pages' drawn window (`sidebar`, `spaces`, `command`, `notes`, `extensions`, `agent`, or several separated by spaces to loop through them). |
| `alt` | What the clip or picture shows, for screen readers. Needed with `video` or `image`. |
| `draft` | `true` keeps it off the live page. |

The build stops with a message if a published entry has no date, or a clip or picture is missing.

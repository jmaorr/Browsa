# Mac release notes

One file per release, `docs/release-notes/mac/<version>.md`. `tools/release-mac.sh <version>` picks it up, and
Sparkle shows it in the update window, so every Mac user who updates reads it.

## Releases so far

| Version | Build | Built from | Date |
|---|---|---|---|
| 1.0 | 338 | `8eefcf8` (main, PR #56) | 2026-11-11 |
| 1.1 | 535 | `7386a31` (main) | 2026-11-17 |
| 1.2 | 578 | `88542ea` (main, PR #88) | 2026-11-19 |

Add a row when a release ships. The build number is the commit count of the ref it was built from
(`release-mac.sh`), so `git rev-list --count <ref>` on the release Mac finds it again. A full clone is needed:
a shallow or grafted clone counts fewer commits.

## Writing the notes

1. List what changed:

   ```sh
   tools/mac-changelog.sh <last release's commit> <ref you'll release>
   ```

   It prints the merged PRs and every commit that touched the Mac app or the shared packages, with their
   message bodies. If the release is built from a branch that isn't main yet (like the daily build), pass
   that branch as the second ref.
2. Keep only what a Mac user can see or feel. Leave out iOS, the website, test tools, logging, debug switches,
   refactors, and anything that was added and taken out again before this release (a feature that came and
   went between releases was never in a release, so it isn't news). Fixes for bugs that never shipped aren't
   news either.
3. Sort what's left into **New** (something you can now do, or a new behaviour worth learning about),
   **Improvements** (something that already worked and now works better, or a new option on something you
   already use) and **Fixes** (something that used to go wrong and now doesn't).
4. Write them in the shape below, then check every setting or menu you name exists in that build, with the
   same words.

## Template

```markdown
**New: <Name>**
<One sentence on what it is and what it does for you.>
*<Optional: where to turn it off or change it, nothing more.>*

**New: <Name>**
<One sentence.>

**Improvements**
- <Short bullet: what works better or what you can now choose, and where.>
- <…>

**Fixes**
- <Short bullet: what works now, in the user's words.>
- <…>
```

## Tone

- Plain and handcrafted. Write the way you'd tell a friend what changed.
- One clean sentence per new feature. If it needs two, it's two features or it isn't simple enough yet.
- Sell it, don't explain it. No narrative lines about how something behaves in edge cases ("closing one of
  several windows…"). The only italic note worth adding is where to switch it off or change it.
- Name things the way the app does: Settings › Audio, Archive, Today tabs, Space. No code names, PR numbers,
  engine internals or device branding.
- Say what you get, not how it was built ("calls sound clear without headphones", not "AEC3 in the capture unit").
- Fixes say what works now ("One swipe moves one Space"), not what was broken.
- Newest and biggest first. Usually three to five New items and a handful of Fixes.
- Sparkle renders the Markdown, so keep to bold, italics and bullets.

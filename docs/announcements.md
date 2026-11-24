# Sidebar announcements (Mac)

Browsa Mac can show one small card at the bottom of the sidebar: a looping clip, a title, a line or
two, a close button and up to two buttons. Cards are published from `website/public/mac/announcements.json`,
served at https://browsa.app/mac/announcements.json, so a new one goes out with a website deploy
(`cd website && npx wrangler deploy`), no app update needed.

The app fetches the file at launch and every 12 hours, with no cookies and nothing in the request
about the person. It keeps the last copy on disk and shows nothing if the file can't be read.
Closing a card, or using an `enable` button, hides that `id` for good, so give every new card a new `id`.

```json
{
  "announcements": [
    {
      "id": "mac-1.3-library",
      "title": "New in the Library",
      "body": "One or two plain sentences.",
      "video": "https://browsa.app/media/whats-new/library.mp4",
      "minVersion": "1.3",
      "maxVersion": "1.3.9",
      "expires": "2027-01-31T00:00:00Z",
      "buttons": [
        { "title": "Turn ’em all on", "action": "enable", "plugins": ["live-folders", "performance", "boosts"] },
        { "title": "Learn More", "action": "library", "target": "live-folders" },
        { "title": "Read more", "action": "open", "url": "https://browsa.app/whats-new/" }
      ]
    }
  ]
}
```

- The first card in the list that fits this version, hasn't expired and hasn't been closed is shown.
- `video` is optional (https only). It's downloaded once before the card appears; muted, looping, 16:10.
- The first button is the prominent one. An `enable` button hides itself once all its plugins are on.
- `enable` takes Library plugin ids from `LibraryCatalog.plugins` (Mac/Sources/Library/LibraryPage.swift).
- `library` opens the Library, at `target` (a plugin or pack id) if given. `open` opens an https page.
- Not shown in private windows.

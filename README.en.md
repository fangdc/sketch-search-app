[简体中文](README.md) · [English](README.en.md)

# SketchSearch

For people who design in Sketch: stop trying to remember which file a screen lives in. Search artboard names, page names, or file names, see the artboard thumbnail on the right, then open the file in Sketch.

SketchSearch builds a local index of your `.sketch` files by parsing Sketch's zip structure and JSON directly — no Python, no third-party libraries. Indexing only reads your files; keyword attributes are written only when Spotlight sync is enabled.

**[Download the latest version](https://github.com/fangdc/sketch-search-app/releases/latest)** · macOS 14 or later · Universal (Intel / Apple silicon)

---

## Features

| Capability | Description |
| --- | --- |
| Instant search | Type an artboard, page, or file name and results update as you type; separate multiple keywords with spaces to require all of them |
| Three result types | Switch between Artboards / Pages / Files in the toolbar; results are sorted by file modification time, newest first |
| Artboard preview | Selecting an artboard exports exactly that artboard with Sketch's own `sketchtool` and shows the thumbnail on the right |
| High-resolution copy | "Copy Preview Image" exports a 3x PNG to the clipboard, capped at 6000 px on the long edge |
| Vector copy | "Copy Vector Artboard" uses Sketch's native pasteboard format; paste into Sketch and the layers stay editable |
| Open and reveal | Open in Sketch, Show in Finder, and Copy Path |
| Single-file browsing | Right-click a result and choose "Show All Artboards in This File" to browse only that file's artboards, then go back to search results |
| Global hotkey | ⌥Space summons the search window from any app |
| Menu bar app | Closing the window keeps the app in the menu bar; background refresh continues and the menu shows index size and last refresh time |
| Automatic refresh | Incremental refresh every 10 minutes by default; also refreshes when you switch back after more than 2 minutes |
| Spotlight sync | Writes artboard and page names into file keywords so ⌘Space can find the `.sketch` file |
| Custom shortcuts | Re-record the summon, refresh, and open shortcuts, or restore the defaults |

### Safety by design

- Only folders you explicitly selected are indexed; nothing is preconfigured on first launch.
- Indexing reads `.sketch` files without modifying, moving, or deleting them.
- Spotlight sync only writes keyword extended attributes and can be fully undone with "Remove Written Keywords".
- No network access, no uploads, no analytics.
- The thumbnail cache is capped at 200 MB and evicts least-recently-used entries.

---

## Requirements

- macOS 14 or later; works on both Intel and Apple silicon.
- No extra components required. Thumbnail preview needs Sketch installed; search still works without it.

---

## Installation

1. Download `SketchSearch-1.0.dmg` from [Releases](https://github.com/fangdc/sketch-search-app/releases/latest), open it, and drag **SketchSearch.app** into Applications.
2. The app is not signed with an Apple Developer certificate, so the first launch is blocked. Allow it once with either method:
   - **Terminal**: `xattr -dr com.apple.quarantine /Applications/SketchSearch.app`
   - **Without Terminal**: double-click → "Cannot be opened" → Done → System Settings → Privacy & Security → Open Anyway.
3. On first run, choose the folders that contain your `.sketch` files.

---

## Getting started

1. The "Welcome to SketchSearch" window appears. Click the folder button (选择文件夹) and pick one or more folders that contain `.sketch` files.
2. Click 开始使用 (Get Started); indexing begins.
3. Type an artboard, page, or file name. Confirm the thumbnail on the right, then press ⌘↩ to open the file in Sketch.

Folders chosen through this window are automatically authorized by macOS. To add or remove folders later, open Settings → 索引目录 (Index Folders).

---

## Interface and shortcuts

| Location | Purpose |
| --- | --- |
| Search field | Type keywords; results update instantly and matches are highlighted |
| Filter | Switch between Artboards / Pages / Files |
| Results list | Artboard results show their page and file name; right-click to open, reveal, copy the path, or show all artboards in the file |
| Preview pane | Shows the artboard thumbnail; zoom with buttons or a trackpad pinch, pan by dragging, reset to fit |
| Bottom buttons | Copy Preview Image, Copy Vector Artboard (artboard results only), Show in Finder, Open in Sketch |
| Toolbar | Copy path, refresh the index, open Settings |
| Menu bar icon | Open the search window, refresh now, see index size, open Settings, quit |

| Shortcut | Action |
| --- | --- |
| `⌥Space` | Summon the search window from any app (configurable) |
| `↑` `↓` | Move the selection; the preview follows |
| `⌘R` | Refresh the index now (configurable) |
| `⇧⌘R` | Rebuild the index, ignoring the cache |
| `⌘↩` | Open the selected file in Sketch (configurable) |

The arrow keys work directly in the search field — you don't need to click the list first. Combinations with ⌘ / ⌥ / ⌃ are left to the system and the menus.

---

## Search and filters

Search matches artboard names, page names, and file names at the same time, and highlights the matched part. Separate multiple keywords with spaces; a result must contain all of them.

The three tabs in the toolbar correspond to artboards, pages, and files:

- **Artboards**: each result is a specific artboard, with its thumbnail on the right; you can copy the preview image or the vector data.
- **Pages**: matches page names. A page has no thumbnail of its own; right-click and choose "Show All Artboards in This File" to preview them.
- **Files**: matches `.sketch` file names and shows the file's cover image on the right.

Results are ordered by file modification time, newest first. Right-click a result to open it in Sketch, reveal it in Finder, copy its path, or browse all artboards in that file.

## Preview and copy

Selecting an artboard exports exactly that artboard with Sketch's own `sketchtool` rather than cropping the page. The first export of a large file has to load the whole document and may take a few seconds; results are cached by file modification time and artboard, so later selections are instant.

In the preview pane you can:

- **Zoom and pan** with the + / − / reset buttons, or pinch and drag on a trackpad.
- **Copy Preview Image** to export a 3x PNG to the clipboard, ready for Figma, Keynote, or a chat window.
- **Copy Vector Artboard** to copy the artboard's layers in Sketch's native pasteboard format; pasting into another Sketch file keeps them editable.

Both copy commands only apply to artboards, so they appear only under the Artboards tab.

## Indexing and auto-refresh

Indexing is incremental: file modification time and size decide whether a file needs to be parsed again, and unchanged files are skipped. Records are removed when a file is deleted or moved out of the indexed folders.

Automatic refresh is on by default and runs every 10 minutes; you can change it to anywhere from 5 minutes to 3 hours in Settings → 索引目录 (Index Folders). Switching back to the app also triggers a refresh if the last one was more than 2 minutes ago. Scanning skips `node_modules`, `.git`, `.Trash`, `Library/Caches`, and `sketch-assets`.

## Spotlight sync

With "Sync Artboard / Page Names to Spotlight Keywords" enabled (the default), the app writes each file's artboard and page names into its Spotlight keyword attribute and calls `mdimport` to refresh the system index. Searching for an artboard name in ⌘Space then finds the corresponding `.sketch` file.

Settings lets you sync immediately or remove all written keywords, and shows how many files are tagged. The system caps keywords per file, so the app limits itself to 18 KB / 900 entries; anything beyond that is searchable only inside the app.

---

## What it does to your computer

- Reads `.sketch` files only inside the folders you selected; it does not modify, move, or delete them.
- When Spotlight sync is enabled, writes the `com.apple.metadata:kMDItemKeywords` extended attribute and calls `mdimport`.
- No network access, no uploads, no analytics.
- Data lives in:

  ```
  ~/Library/Application Support/SketchSearch/
  ├── index.db           SQLite index
  ├── thumbs/            Artboard thumbnail cache (200 MB cap)
  └── sketchsearch.log   Runtime log
  ```

- Copying a preview image creates a one-off file in the system temporary directory and deletes it afterwards; leftovers from a crash are cleaned up on the next launch.
- **Complete uninstall**: quit the app, delete `/Applications/SketchSearch.app`, then delete `~/Library/Application Support/SketchSearch/`. If you no longer want the Spotlight keywords, click "Remove Written Keywords" in Settings → 聚焦搜索 (Spotlight) first. To remove preferences as well, run `defaults delete com.sksearch.app`.

## Known limitations

- **No jumping to a specific artboard**: Sketch provides no API to open a file at an artboard, so the app can only open the file; you still click the artboard in Sketch.
- **Spotlight keyword cap**: files above roughly 18 KB / 900 entries are truncated by the system; the extra names are searchable only inside the app, and Settings shows how many files were truncated.
- **Re-saving in Sketch may drop the keyword attributes**; the next automatic refresh restores them.
- **No thumbnails without Sketch installed**; search, filtering, copying paths, and copying vector artboards still work.
- **Gatekeeper needs one manual approval**, because the app is ad-hoc signed and not notarized by Apple.

---

## License

[MIT License](LICENSE), copyright holder: DACONG.

You may use, modify, and redistribute it freely, including in commercial projects, as long as the copyright and license notices are retained.
The software is provided "as is", without warranty of any kind.

Sketch is commercial software by Bohemian Coding. This project is not affiliated with Bohemian Coding; the name "Sketch" is used only to describe what the tool works with.

macOS and Apple are trademarks of Apple Inc. This project is not affiliated with Apple Inc.

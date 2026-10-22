<p align="center"><img src="docs/icon.png" width="128" alt=""></p>

<h1 align="center">WordPop 划词查词</h1>

<p align="center">Look up any English word anywhere on your Mac: double-click it, or tap ⌘ once, and its entry from the Oxford English–Chinese dictionary pops up.<br>Every word you look up goes into a vocabulary list and shows in red the next time.</p>

<p align="center"><a href="README.md">中文</a></p>

<p align="center">
  <img src="docs/popup-first.png" width="380" alt="First lookup: added to the list">
  <img src="docs/popup-again.png" width="380" alt="Looked up again: marked red">
</p>

## Features

- **Double-click or drag across** an English word in any app (Chrome, Safari, WeChat, Word, Notion…) to see its definition
- **Tap ⌘ once** to look up the selection, or, with nothing selected, the word under the pointer: text in images, screenshots, video subtitles and mixed Chinese–English text is read with on-device OCR
- **Vocabulary list**: looked-up words are added automatically, marked red with a lookup count when they come up again, and removed with one click; the list is a plain text file
- Uses macOS's built-in Oxford English–Chinese dictionary: offline, a few milliseconds per word; US pronunciation
- Lives in the menu bar at about 20 MB and no CPU when idle; OCR runs in a separate process that quits after 3 idle minutes

## Install

1. Download `WordPop-x.y.z.dmg` from [Releases](https://github.com/wrab12/wordpop/releases/latest) and drag WordPop into Applications.
2. The first time you open it, macOS says it can't verify the developer: click Done, then go to **System Settings → Privacy & Security** and click **Open Anyway** near the bottom. Or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/WordPop.app
   ```
3. Grant the permissions it asks for:
   - **Accessibility** (required), to read the selected text
   - **Screen Recording** (optional), to read the word under the pointer when nothing is selected
4. If the menu says the Oxford English–Chinese dictionary is missing, open the Dictionary app → Settings and tick "Simplified Chinese – English".

Requires macOS 13 or later (reading text off the screen needs macOS 15.2 or later), on Apple silicon or Intel.

## Usage

| Do this | To |
|---|---|
| Double-click or drag across an English word | See its definition |
| Tap ⌘ once (press and let go) | Look up the selection, or the word under the pointer |
| Click 移出生词本 on the card | Remove the word from the list |
| Press any key, click elsewhere or scroll | Close the card |

From the menu bar icon you can pause automatic lookups, turn them off for one app (code editors are off by default), open the vocabulary list and start WordPop at login.

## Vocabulary list

`~/Library/Application Support/WordPop/生词本.txt`, one word per line: word, meaning, first looked up, times looked up, separated by tabs. Edit it freely; deleting a line removes the word.

## Privacy

Everything stays on your Mac: definitions come from the local dictionaries and OCR uses Apple's on-device Vision framework. Nothing is sent anywhere. Screen Recording is used only when you tap ⌘, for a small strip around the pointer, and nothing is saved.

## Building from source

Only the Xcode Command Line Tools are needed (`xcode-select --install`):

```bash
./build.sh install   # build and install to ~/Applications
./build.sh test      # run the tests
./build.sh release   # package dist/WordPop-x.y.z.dmg and .zip
```

To release: bump the version in `mac/Info.plist`, add the changes to `CHANGELOG.md` and push a `vX.Y.Z` tag; GitHub Actions builds and publishes the release.

## License

[MIT](LICENSE)

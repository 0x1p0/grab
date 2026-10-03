# Grab

**Copy literally anything on your Mac by pointing at it.**

Hold <kbd>⌥</kbd>, hover, press <kbd>C</kbd>. A glowing border shows exactly what you're about to grab, and a small HUD shows what kind of thing it is. No dragging rectangles, no selecting text, no right-clicking.

| Point at… | You get… |
|---|---|
| Text (any app, any web page) | The paragraph, line, sentence or word |
| A link | Its URL |
| An image | The image (the original file for web images, otherwise pixel-perfect) |
| A QR code / barcode | The decoded value |
| A color | `#ED6E2A` (or RGB / HSL / SwiftUI, your choice) |
| A file in Finder | The file itself (paste into Finder, Mail, Slack…) or its path |
| Text inside an image, video, canvas or game | The recognized text (on-device OCR) |
| Code | A symbol, expression, string, line, statement, `if`/`for` block, **function**, class or the whole file |
| A table | A cell, row, **column** or the whole table (pastes into spreadsheets as cells) — even a table inside a screenshot |
| A Wi-Fi QR code | The password or network name (<kbd>Tab</kbd>) |
| A command in a terminal | The command without the prompt, or its output |
| A date, phone number, address, price, measurement… | The text, or <kbd>Tab</kbd>: ISO 8601 · Unix · a calendar event · E.164 · Apple Maps · your currency · metric/imperial |
| JSON, a JWT, base64, a Unix timestamp, a sum | Pretty / minified JSON, the decoded payload, a readable date, the result (`1,240 × 12%` → `148.8`) |
| A stack trace or error | The error line, a search link, or the trace with library frames folded away |
| A list, menu or dropdown | Every item, as lines, bullets, numbers, comma-separated or a JSON array |
| A form | Every field as JSON (password fields skipped) |
| A photo | The image, just its **subject** (background removed), its color palette or a data URI |

## Keys

While holding <kbd>⌥</kbd>:

| Key | Does |
|---|---|
| <kbd>C</kbd> | Copy |
| <kbd>←</kbd> <kbd>→</kbd> | Switch type: Text · Link · QR · File · Image · Color |
| <kbd>↑</kbd> <kbd>↓</kbd> | Grow / shrink the area: word → line → sentence → paragraph → block → window (in code: symbol → line → block → function → class → file) |
| <kbd>Tab</kbd> | Switch format: code as-is / Markdown block / `file.swift:10-34` reference, links as Markdown, tables as cells / Markdown / CSV, colors as HEX / RGB / HSL / SwiftUI |
| <kbd>⇧</kbd><kbd>C</kbd> | Add it to the **shelf**: a floating list you can reorder; the clipboard always holds the whole shelf |
| <kbd>⏎</kbd> | **Open** it: links, files, Maps for addresses, Calendar for dates, FaceTime for phone numbers, the tracking page for parcels, a web search for anything else |
| <kbd>Space</kbd> | **Quick Look** the file, image or text |
| <kbd>P</kbd> | **Pin** it on screen in a small floating window (text stays selectable) |
| <kbd>S</kbd> | **Speak** it (again to stop) |
| <kbd>T</kbd> | **Translate** it (Apple's on-device translation) |
| <kbd>E</kbd> | **Ask** on-device AI: explain, summarize, fix OCR'd text, turn it into JSON, or ask your own question |
| <kbd>Z</kbd> | **Undo** the last grab and put back what was on the clipboard |
| <kbd>Esc</kbd> | Cancel |

Release <kbd>⌥</kbd> and everything disappears.

Grab picks a smart default for whatever is under the cursor (a link gives Link, a photo gives Image, a QR code gives its value, a plain colored area gives Color), and remembers your ← → choice for the rest of that ⌥ hold.

## Code

Point at code anywhere and Grab understands its structure:

- **Point at a function's signature** and you get the whole function, with its doc comment and attributes. Point inside and you get the line; <kbd>↑</kbd> walks out through the `if`/`for` block, the function, the class and the file, <kbd>↓</kbd> goes in to the expression and symbol.
- Copied blocks are **dedented**, so they paste cleanly. <kbd>Tab</kbd> switches to a fenced Markdown block (with the language) or a `path:line` reference.
- Works in **Xcode** and other native editors, **Terminal / iTerm**, **VS Code**, **Cursor** and other VS Code forks, code blocks on web pages (GitHub, docs, AI chat answers) in **Safari, Chrome** and Electron apps, and even code in screenshots and videos.
- How: native editors and Safari report exact character positions. VS Code-style editors draw text without exposing it, so Grab reads the open file from disk (or finds it with Spotlight from the tab name), OCRs the screen once and aligns the two using the line numbers in the gutter, so what you copy is the real file content, not OCR. It never turns on screen-reader modes in your editor.
- Understands brace languages (Swift, JS/TS, Go, Rust, C/C++/ObjC, Java/Kotlin, C#, PHP, CSS…), indentation languages (Python, YAML) and `end` languages (Ruby, Lua, Elixir).
- Terminals: hover a prompt line for the **command** (prompt stripped), output lines for the **output** block, a path for the **file** itself (`Sources/App.swift:12:4` included).
- Colors written in code or CSS (`#ED6E2A`, `0xED6E2A`, `rgb(…)`, `hsl(…)`) become grabbable colors.

## Smart formats

<kbd>Tab</kbd> offers formats for whatever Grab recognizes, and remembers your choice per kind (dates, prices, JSON… each keep their own). The HUD previews exactly what will be copied.

- **Dates & times** → ISO 8601, your local time, Unix time, or an `.ics` **calendar event** titled from the surrounding text ("Team sync on…"). "Due March 3" means March 3.
- **Phone numbers** → `+15551234567` (your region fills in the country code), digits only, or a `tel:` link. **Emails** → the address or a `mailto:` link. **Addresses** → one line, Apple Maps or Google Maps.
- **Prices** → the plain number, or converted to your currency with the ECB's daily rates (only currency codes are fetched). **Measurements** → metric ⇄ imperial (`12 ft` → `3.66 m`, `72°F` → `22.2°C`).
- **Tracking numbers** (UPS, USPS, FedEx, DHL, Amazon), **flights**, **ISBNs** and **DOIs** → the clean number or the right tracking/lookup page.
- **Developer bits** → JSON pretty/minified (key order and numbers kept exactly), JWT header/payload, base64 decoded, timestamps as dates, sums evaluated, stack traces cleaned. CSS selectors for web elements, font name/size/weight/color for text (CSS in browsers), and **GitHub / GitLab permalinks** for code (`…/blob/<commit>/path#L12-L30`).
- **Quote with source** ("Cite") adds the page title and URL. **YouTube** videos: Link → "At current time" gives `youtu.be/…?t=93`.
- **Paste-aware code.** Code you copy adapts when you paste it: no `$` prompts in a terminal, a fenced code block in Slack, Discord, Notion or Obsidian.

## Privacy

- **Secrets stay secret.** API keys, tokens, private keys and Wi-Fi passwords are marked concealed (clipboard managers skip them), kept out of history, and cleared from the clipboard after a minute.
- Password fields are never read. History and the shelf live in memory only. OCR, translation and AI run on your Mac.

## Precision

- **Words everywhere.** Safari, Chrome and Electron apps all give word → sentence → line → paragraph, down to a single timestamp, count or username.
- **Sees through overlays.** Sites like Reddit lay invisible links over cards; Grab looks underneath for the text you're actually pointing at, and keeps the card's link one <kbd>←</kbd> <kbd>→</kbd> away.
- **OCR that holds up.** Apple's document recognizer (paragraphs, lines, words, tables) at full resolution around the cursor, with a second focused pass when the first misses a line, and the model warmed up at launch so the first grab isn't slow.
- **QR codes, reliably.** A tight multi-scale scan around the cursor reads codes wherever they are — images, CSS backgrounds, canvases, video — including inverted, colored, logo-in-the-middle and tiny ones.
- **Objects nothing describes.** Pictures, icons and color blocks that apps don't expose are outlined from the pixels: solid blocks become colors, pictures become images.

## Details

- **Smart targeting.** Uses the macOS accessibility tree for exact text ranges in native apps, Safari, Chrome, Electron and Firefox, then falls back to on-device Vision (OCR + barcode detection) for anything drawn as pixels.
- **Exact colors.** Colors are sampled through the system's own color-managed capture path, so the hex you copy is the hex the page specified, even on P3/HDR-capable displays. In Color mode a magnifier loupe shows the exact pixel.
- **Gets out of the way.** ⌥-click, ⌥-drag, ⌥⇧ shortcuts and typing with ⌥ all behave as before; Grab only activates for a deliberate ⌥ hold. If you were just typing, it waits for the mouse to move, so ⌥← / ⌥→ word-jumping keeps working. Apps where ⌥ already means something (like Figma's measurement guides) can be excluded from the menu bar.
- **Never in your captures.** The overlay is hidden from screenshots and screen recordings by default (there's a setting to show it when recording a demo).
- **Feel.** Synthesized sounds, trackpad haptics, a spring-animated border with a sweeping sheen, a Liquid Glass HUD, and a little chip that flies to the menu bar when you copy. Respects Reduce Motion.
- **Recent grabs.** The menu bar icon keeps your last grabs; click one (or press 1–9) to copy it again, or **Search History…** to find any by text, app or page. History lives in memory only and is never written to disk.
- **Per-app preferences.** "In Figma, prefer Color", "In Safari, prefer Link": set a favorite type per app from the menu bar or Settings.
- **Automation.** `grab://copy?mode=text` grabs what's under the pointer (bind it to a key in Shortcuts), plus `grab://history`, `grab://shelf`, `grab://pause` / `resume` / `toggle`.
- **Accessibility.** VoiceOver announces what's targeted and what was copied; *Increase Contrast* gets a thicker, solid border.
- **Light.** ~0% CPU when idle, ~1% while the overlay is up.

## Promo video

**[Watch the 30-second promo](promo/Grab-promo.mp4)**: motion graphics at 1080p60 with an original synthesized soundtrack. Every frame and every sound is generated by code: `scripts/promo/render.sh` re-renders it into `promo/Grab-promo.mp4` in about two minutes.

## Install

Requires macOS 14 or later (best on macOS 26+) and Xcode command line tools.

```bash
scripts/build.sh --install --run
```

That builds a release `Grab.app`, signs it with your Apple Development certificate if one is in your keychain (so macOS remembers its permissions across rebuilds), copies it to `/Applications`, and launches it.

On first launch, Grab asks for two permissions:

- **Accessibility** (required): to see what's under the cursor and hear ⌥C.
- **Screen Recording** (for images, colors, QR codes and OCR): macOS asks you to relaunch Grab after you switch it on.

Other build options:

```bash
scripts/build.sh            # release build → build/Grab.app
scripts/build.sh --debug    # debug build with command-line debug hooks (see AppDelegate)
```

## How it's put together

```
Sources/Grab/
  App/        AppDelegate (wiring, permissions, debug hooks), main
  Engine/
    KeyTap        system-wide ⌥ state machine on its own thread
    KeyLayout     which physical key types "c" in your keyboard layout
    Inspector     accessibility tree → ranked "scopes" (word … window)
    Session       one ⌥ hold: targeting, modes, formats, OCR/QR analysis, copying
    CodeIntel     lexer + structure finder: symbols, statements, blocks, functions, types
    CodeGrid      learns where each line of code sits on screen from OCR + the real text
    Inspector+Code  code detection for editors, terminals and web code blocks
    SmartData     colors and file paths written in text
    SmartTypes    dates, phones, addresses, prices, units, tracking numbers, JSON,
                  JWT, base64, timestamps, math, stack traces + their formats
    Inspector+Extras  lists, form fields, fonts, CSS selectors, video timestamps
    ImageTools    subject lifting, palettes, data URIs, icons
    Git           repository → GitHub/GitLab/Bitbucket permalinks (reads .git, never runs git)
    TextReader    OCR (document structure) + QR/barcode scanning
    VisualObjects finds pictures/icons/swatches from pixels
    Formats       Tab-cyclable output formats
    ScreenGrabber ScreenCaptureKit capture + Vision OCR / barcodes
    Model         scopes, modes, colors, payloads
  Overlay/    per-display click-through windows; border + spotlight on Core
              Animation (springs run in the render server), HUD/loupe/toast in SwiftUI
  UI/         menu bar item, onboarding + playground, settings, panels (pins,
              Ask/translate, shelf, history, Quick Look)
  Support/    settings, permissions, sounds (synthesized), clipboard (undo,
              secrets, paste-aware code), history + shelf, on-device AI, speech
scripts/      build.sh, make_icon.swift (renders the app icon)
Tests/        CodeIntel, SmartData, SmartTypes and Formats unit tests (`swift test`)
```

## Notes

- **Secure input.** When another app enables Secure Keyboard Entry (password fields, some terminals), macOS hides keystrokes from every app, Grab included; the HUD tells you when that's the case.
- **Typing ç.** With *Instant ⌥C* on (default), ⌥C always grabs. If you type ç with ⌥C, turn it off in Settings; then ⌥C only grabs once the border is showing.

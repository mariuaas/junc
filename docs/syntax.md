# Syntax highlighting

junc highlights `.zig`, `.lua` and `.fnl` files through Litura’s Tree-sitter providers, enabled by default. Unknown extensions and scratch documents remain plain text. Litura supplies grapheme-based token spans; the server caches the visible range and the client applies the Lua palette while rendering terminal cells.

## Litura API and coordinates

The integration calls `tree_sitter.TreeSitterTokenProvider.attachTokensBuiltin(document, language)` to attach the token facade. The separate syntax-node facade is unused. Litura owns the provider and releases it when the document is destroyed. Attachment creates parser/query resources but does not parse the document.

`queryViewState("tokens")` reports availability and revision. `queryTokenSpans(start, end, document.revision)` rejects a non-head revision and returns an owning array allocated by the document allocator. Each `TokenSpan` has half-open `start`/`end`, original capture `kind` (such as `keyword.function` or `string.escape`), and normalized `style` (such as `syntax:keyword`). The nested strings belong to the provider; junc copies only positions and normalized category enums into its own cache.

Tree-sitter operates in UTF-8 bytes internally. Litura converts captures to grapheme offsets at its public boundary using its own grapheme-to-byte map. junc does not repeat that conversion. The renderer asks for one contiguous range bounding the visible rows; spans can extend beyond that range. It looks up the category at each rendered grapheme position, then advances the terminal column using libvaxis width measurement and the existing tab/clipping rules. Horizontal scrolling clips cells, not protocol positions. A partially clipped wide grapheme is omitted rather than split.

## Lua styles

Each presentation preset can define an optional `syntax` table:

```lua
syntax = {
  keyword = {fg='#c792ea', bold=true},
  string = {fg='#b8ce9a'},
  comment = {fg='#718779', italic=true},
  ['function'] = {underline=true},
},
```

The nine supported keys map exactly to Litura's normalized styles:

| Lua key | Litura style and representative captures |
| --- | --- |
| `comment` | `syntax:comment`; comment, comment.documentation |
| `string` | `syntax:string`; string, string.escape, character |
| `number` | `syntax:number`; number, number.float, float |
| `constant` | `syntax:constant`; constant, constant.builtin, boolean |
| `keyword` | `syntax:keyword`; keyword subcategories, conditional, repeat, label, preproc |
| `function` | `syntax:function`; function subcategories, method |
| `identifier` | `syntax:identifier`; variable, parameter, type, module, field, attribute, constructor |
| `operator` | `syntax:operator`; operator |
| `punctuation` | `syntax:punctuation`; punctuation subcategories |

Foreground colors use the existing `"default"`, palette index or `"#RRGGBB"` representation. `bold`, `italic` and `underline` are optional booleans. Unspecified categories inherit base text; an omitted foreground retains the base foreground. Unknown categories/attributes and invalid values reject the replacement presentation, including errors in inactive presets. Classic assigns colors to more token groups; Minimal uses fewer colors and mostly inherits base text.

Precedence is base text → syntax → selection → cursor. Selection and cursor completely replace token styling, including attributes. The existing NO_COLOR behavior still suppresses colors while retaining useful attributes and inverse selection/cursor cells.

Style tables are validated and copied into a fixed native array during presentation resolution, once per presentation/frame refresh rather than per cell. Cell construction never calls Lua. Ctrl-R uses the existing candidate-VM transaction. Rejected styles leave the old commands and palette active; successful color reload leaves the Litura document, provider, session, revisions and undo history intact. Palette changes never mark the syntax tree stale.

## Refresh, caching and limits

At pinned Litura revision `4864521859c7106f89326d9936c3d0a17dff1e35`, edits (including undo/redo) mark the provider stale. The first `queryTokenSpans` on a stale revision synchronously copies the full document, calls `parseString(text, null)`, builds a full grapheme map and runs all highlight queries. It does not reuse the old parse tree incrementally. Later visible queries scan the cached full-document spans and return intersecting entries. A narrow viewport therefore reduces the returned spans, but the stale refresh still processes the full document and later queries still scan its cached captures.

junc caches the normalized visible spans by document revision and row range. Repainting, cursor movement within the same rows, horizontal scrolling, and palette reload reuse that cache. Vertical scrolling or resize may query a new range, but do not rebuild the provider at the same revision. A failed refresh drops stale colors and is retried only after the document revision changes; editing remains available. Absent or unavailable providers fall back to base text.

`zig build bench-syntax` measures the unmodified provider's initial refresh, a repeated 200-grapheme query, and a refresh after an edit. A recorded synthetic run with the earlier `bea86d0` pin on macOS arm64 used repeated short source lines containing CJK and combining text:

| Source size | ReleaseSafe refresh, Zig/Lua/Fennel | Debug refresh, Zig/Lua/Fennel |
| --- | --- | --- |
| 16 KiB | 5 / 4 / 7 ms | 51 / 55 / 98 ms |
| 128 KiB | 31 / 34 / 55 ms | 392 / 435 / 767 ms |
| 1 MiB | 260 / 304 / 573 ms | 3172 / 3525 / 6210 ms |

Repeated provider queries took roughly 2–142 microseconds in ReleaseSafe and 0.36–1.36 ms in Debug. junc's unchanged-viewport cache avoids even those calls. These are single-run observations, not latency guarantees; grammar structure and hardware matter.

Because every edited revision incurs synchronous work, junc defaults to plain text above **128 KiB** instead of allowing multi-hundred-millisecond or multi-second refreshes on larger documents. This is a host responsiveness policy, not a Litura size limit or a promise that all smaller documents parse quickly. Use `zig build -Dsyntax-max-bytes=N` to change it, `-Dsyntax-max-bytes=0` to remove it, or `-Dtree-sitter=false` to omit parsers entirely. A document that shrinks below the bound can resume highlighting. Prefer ReleaseSafe for interactive source editing. The provider may retain its previous tree while an enlarged document is displayed as plain text.

## Remaining library boundaries

The integration uses the published Litura package without modifying it. Reducing the full-refresh and linear cached-query costs requires provider work. Litura also resolves overlapping captures itself, keeping sorted non-overlapping spans; junc uses that result rather than applying independent capture priority rules. Raw capture subcategories are available in `kind`; the presentation API styles only the normalized groups. Existing Litura transaction/allocation-failure limitations remain as documented in its known-issues file.

## Verification

`zig build test` exercises all three providers, grapheme-coordinate string spans, refresh after editing/undo/redo, cache reuse after scrolling and palette reload, missing/unavailable providers, size fallback, native Unicode cells and horizontal clipping, and selection/cursor precedence. The parser-disabled test build verifies plain-text editing. `tests/syntax_terminal.py` opens copies of junc's own Zig and Lua code, edits and scrolls, changes presets, edits a syntax color in the open Lua presentation file, saves/reloads it without changing revisions, rejects a bad palette and verifies resize and terminal restoration. The existing editing and presentation PTY suites remain applicable.

With [server hosting](daemon.md), providers and their refresh cache live beside each authoritative server document. Visible text, grapheme byte boundaries and token spans arrive together in a revision-stamped view. The client renders straight from the spans in that view, so there is one syntax cache per buffer and none per client; it does not attach a parser or segment main-document text locally.

# Syntax highlighting

junc highlights `.zig` and `.lua` files through Litura’s Tree-sitter providers, enabled by default. Unknown extensions and scratch documents remain plain text. Litura supplies grapheme-based token spans; the server caches the visible range and the client applies the Lua palette while rendering terminal cells.

## Litura API and coordinates

The integration calls `tree_sitter.TreeSitterTokenProvider.attachTokensBuiltin(document, language)` to attach the token facade. The separate syntax-node facade is unused. Litura owns the provider and releases it when the document is destroyed. Attachment creates parser/query resources but does not parse the document.

`queryViewState("tokens")` reports availability and revision. Queries never refresh. A visible-range request never refreshes: it returns current text with empty tokens and `syntax_state=stale` until scheduled maintenance finishes. Before querying tokens, junc verifies that the provider state belongs to the current document revision. A stale or unavailable registered view raises `ViewStale` or `ViewUnavailable`, rather than silently returning an empty token list. `queryTokenSpans(start, end, document.revision)` rejects a non-head revision and returns an owning array allocated by the document allocator. Each `TokenSpan` has half-open `start`/`end`, original capture `kind` (such as `keyword.function` or `string.escape`), and normalized `style` (such as `syntax:keyword`). The nested strings belong to the provider; junc copies only positions and normalized category enums into its own cache.

Tree-sitter operates in UTF-8 bytes internally. Litura converts captures to grapheme offsets at its public boundary using piece-tree byte/grapheme mappings. junc does not repeat that conversion. The renderer asks for one contiguous range bounding the visible rows; spans can extend beyond that range. It looks up the category at each rendered grapheme position, then advances the terminal column using libvaxis width measurement and the existing tab/clipping rules. Horizontal scrolling clips cells, not protocol positions. A partially clipped wide grapheme is omitted rather than split.

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

At pinned Litura revision `781dac1dc57f44c1dbdfc6c9cceda5df1aa5a06f`, committed edits (including undo/redo) deliver realized splices to the provider in grapheme, byte and row/byte-column coordinates. The provider applies those splices to its previous tree and incrementally reparses when the host calls `refreshView`. It reads the piece tree directly, maps coordinates using tree aggregates and generates captures for the requested range. A narrow query no longer triggers a full-document capture pass or a separate full grapheme map.

junc caches normalized visible spans by document revision and row range. Repainting, cursor movement within the same rows, horizontal scrolling and palette reload reuse that cache. Vertical scrolling or resize may query a new range, but do not parse again at the same revision. A failed refresh drops stale colors and is retried only after the document revision changes; editing remains available. Absent or unavailable providers fall back to base text.

The daemon owns the schedule. After servicing ready socket events it polls again without waiting; queued client frames and new connections take priority. Only when input is quiet does it give one selected, previously observed buffer a nominal **4 ms** refresh slice, rotating among active buffers. The next turn checks input again. Detached and unobserved buffers receive no background work, and completed/unavailable views leave the work queue. There are no worker threads or per-client syntax trees.

A halted parse stays stale and resumes on later idle turns. An edit during that work creates another document revision; Litura carries the pending changes forward, and junc exposes tokens only when the provider reaches the current head. Old token coordinates are never paired with new text. Completion advances the host's coalescible observation generation and invalidates every client selecting that buffer, so highlighting can appear without another key or resize. These signals are hosting invalidations, not document edits or canonical Litura events.

**There is no highlighting size cutoff.** The former 128 KiB gate and `syntax-max-bytes` build option are removed. `-Dtree-sitter=false` still omits built-in parsers. File-open and transport-frame limits remain separate resource bounds. Continuous input may leave highlighting stale until the server has spare time. Tree-sitter checks its budget cooperatively, so an individual call can overrun four milliseconds; the host neither treats that as failure nor raises a new file-size threshold.

`zig build bench-syntax -Doptimize=ReleaseSafe` measures total refresh work, longest slice, slice count and a 200-grapheme query, before and after an insertion at the document midpoint. A single macOS arm64 run with Zig 0.16.0 and repeated lines containing CJK/combining text measured:

| Source size | Initial work, Zig / Lua | Post-edit work, Zig / Lua | Longest post-edit slice, Zig / Lua | Post-edit query, Zig / Lua |
| --- | --- | --- | --- | --- |
| 16 KiB | 1.2 / 1.9 ms | 0.3 / 0.9 ms | 0.3 / 0.9 ms | 55 / 38 µs |
| 128 KiB | 8.2 / 15.1 ms | 1.7 / 8.5 ms | 1.7 / 4.0 ms | 52 / 43 µs |
| 1 MiB | 65 / 125 ms | 14 / 66 ms | 4.3 / 5.3 ms | 59 / 62 µs |

The initial 1 MiB parses took 17 and 31 slices; their longest calls were 4.2 and 6.4 ms. These are provider measurements, not end-to-end keystroke guarantees. The process tests separately exercise queued input and idle completion. `InProcessHost` embedders drive `maintain(budget)` explicitly outside request handling and poll their connection's invalidations afterward; deterministic tests can supply an unlimited budget to that maintenance call.

## Syntax-node boundary

The editor currently attaches only the token facade; expand/shrink commands are a separate workload. The migration tests also exercise Litura's combined token/syntax attachment. `SyntaxNodeRef` now contains `provider`, `revision` and an opaque numeric `id`, with no retained node path. Node references resolve only while their revision is current. `queryEnclosingSyntaxNode` propagates provider errors and returns null for leading whitespace outside every node; callers must distinguish absence from stale or unavailable syntax.

## Remaining library boundaries

Litura owns parsing, capture overlap resolution, node references and all byte/grapheme conversion. junc stores only normalized categories and grapheme ranges. Incremental parsing still has costs proportional to long syntax lists and can approach a full reparse when an edit changes the rest of the file. Tree-sitter checks budgets cooperatively, so even a bounded refresh can overrun its requested deadline. Syntax-error recovery can differ from a fresh parse; the upstream known issues also record a grammar-specific incremental divergence and Tree-sitter's abort-on-exhaustion allocator. See the pinned [incremental syntax design](https://github.com/mariuaas/litura/blob/781dac1dc57f44c1dbdfc6c9cceda5df1aa5a06f/docs/development/incremental-syntax.md) and [known issues](https://github.com/mariuaas/litura/blob/781dac1dc57f44c1dbdfc6c9cceda5df1aa5a06f/docs/known-issues.md) for the upstream evidence and limits.

## Verification

`zig build test` exercises both supported providers, grapheme-coordinate string spans, explicit refresh and halted-parse resumption, revision-bound node references, byte/point splices, refresh after editing/undo/redo, cache reuse after scrolling and palette reload, missing/unavailable providers, large-file scheduling, native Unicode cells and horizontal clipping, and selection/cursor precedence. The parser-disabled test build verifies plain-text editing and dormant upkeep when no provider is installed. `tests/syntax_terminal.py` opens copies of junc's own Zig and Lua code, edits and scrolls, changes presets, edits a syntax color in the open Lua presentation file, saves/reloads it without changing revisions, rejects a bad palette and verifies resize and terminal restoration. The existing editing and presentation PTY suites remain applicable.

With [server hosting](daemon.md), providers and their refresh cache live beside each authoritative server document. Visible text, grapheme byte boundaries and token spans arrive together in a revision-stamped view. The client renders straight from the spans in that view, so there is one syntax cache per buffer and none per client; it does not attach a parser or segment main-document text locally.

`python3 tests/syntax_schedule_test.py` pipelines observe/edit requests to prove input-first scheduling, waits for completion without sending another request, and checks large-file and two-observer invalidations. `python3 tests/syntax_schedule_terminal.py` opens more than 1 MiB of Unicode source, checks a plain first frame, waits for idle highlighting, edits/resizes, and verifies catch-up and terminal restoration. Native tests also edit while a parse is halted and reject stale coordinates after undo.

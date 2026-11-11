# Junc style guide

These conventions guide work on Junc’s Zig host, Lua policy and integration tests. Adapted from Litura’s Zig style guide, they cover structure, naming, ownership and review while preserving the project’s documented behavior.

## Principles and precedence

When a rule here and a specified contract disagree, the contract wins.

1. The documented contracts in [the README](../README.md) and the linked API and design documents are authoritative for Junc's observable behavior. A dependency's specification governs that dependency, including while it is still a draft; it does not establish that Junc implements every specified feature. Style is not a reason to change behavior.
2. Correctness outranks style. Make ownership, failure behavior and caller-visible invariants explicit.
3. These are defaults for new and edited code. Leave an existing name or shape alone during ordinary maintenance. A deliberate, behavior-preserving change of structure is a valid reason to rename or reshape it, and it does not need to ride along with another edit.
4. Libraries and applications share the rules. A library does not grow a process, a window, or host policy. An application composes library instances. Projects need not share one internal architecture.

## Application boundaries

Litura owns document text, grapheme segmentation, anchors, interaction sessions, revisions, undo and persistence. The server hosts the shared document registry and its sessions. A terminal client owns its Lua VM, presentation, viewport and local minibuffer; queried main-document views are observations of server state. Keep those lifetimes explicit. In-process test hosts exercise the same editing adapter without establishing transport behavior.

Lua supplies command implementations, keybindings and presentation policy. Zig validates and realizes intents, owns native resources and lays out terminal cells. libvaxis handles terminal decoding, capabilities, width measurement and rendering. Add behavior at the layer that owns it. Do not duplicate document mutation, Unicode segmentation or terminal decoding in a neighboring layer.

Ordinary commands, extension commands and native input replacements use the shared submission adapter. Preserve buffer identity and document and interaction revision origins through that path. A stale coordinate request is rejected and refreshed; it is not silently restamped or replayed. Keep byte offsets, grapheme offsets, line numbers and terminal-cell offsets distinct, and document every conversion.

Host attachment and teardown may use the dependency's intrinsic lifetime APIs. They are not an alternate editing path. Dependency limitations belong beside the affected contract; a local workaround must not claim a stronger library guarantee. See [the Lua submission boundary](lua-api.md) and [server ownership and transport](daemon.md).

## Modules, naming, and public APIs

The `junc` module exposes its host and bridge API through `src/root.zig`. The terminal surface and executable have separate build modules so terminal dependencies stay at the terminal boundary. A module root publishes the namespaces and the few aliases a caller is meant to write. A caller who needs a submodule imports it. Re-export a name only when that spelling is the supported one. A file kept only so an old import still resolves states, on its first line, the condition for removing it.

One implementation file holds one concept. Outside a module root, a catalogue of unrelated re-exports is a signal to split it. Directories are `snake_case`. A namespace file is `snake_case.zig`. A file whose only job is one instantiable type may be `TitleCase.zig`.

Names follow ordinary Zig:

- Functions are `camelCase`. Types, and functions that return a type, are `TitleCase`.
- Values, fields, and constants are `snake_case`.
- An acronym is a word: `readU32Be`, not `readU32BE`.
- Spell words out: `message`, `source`, `target`. A single letter is enough for an index in a tight numeric loop.
- Put the unit or qualifier last, so related names align: `latency_ms_min` beside `latency_ms_max`.
- Do not repeat the module in the type. In `protocol.zig` the type is `Request`, so the call reads `protocol.Request`.
- Skip empty words (`Manager`, `Context`, `Utils`) unless the word is the domain term.
- Name an allocator for the policy it carries when that changes cleanup: `gpa` or `arena`.

A closed set of modes is an enum. An open wire value is a non-exhaustive enum (`enum(u16) { _, }`) or a raw field beside a known-kind enum. Strings are for text that is actually text.

`anytype` is for a documented caller-supplied source at a library boundary, or a tiny local helper. If the concrete type lives in this repository, name it. Two arguments of the same integer type that a caller could swap take an options struct, or names that make the call unambiguous. A nullable argument is a named field, so `null` means something at the call site.

The public surface is what another file may call. The rest is private. Inside a struct, write fields, then nested types, then methods. Move a nested type to a top-level declaration when its size makes the enclosing type difficult to follow.

Mutable state sits on an instance the caller creates, not in a file-scope `var`. A file-scope variable is for something the process truly has one of, and it should be rare. `main` wires instances and runs the loop. Parsing, editing and rendering do not live there. Host policy (paths, attachment, shutdown) lives on the host instance responsible for it.

A library does not initialize its platform, open a window, or read process arguments. Declare every dependency, and say what it is for. Keep it out of subsystems that do not use it. An application may depend on the platform it is. New C bindings are produced with `translate-c` in `build.zig`.

## Types, memory, errors, and invariants

Document ownership on the type, or on the function that returns it: who allocates, who frees, whether the caller must keep the input alive, and what a shallow copy would do. After `deinit` releases its resources, it sets `self.* = undefined`, so a later use is visible in safe builds.

The allocator is a parameter of `init`, or of the function that allocates, and is stored on the object that frees. There is no process-wide allocator variable.

Borrowed input and an owning value stay separate when a library offers both. A borrowed view does not take ownership of its input. If it retains a pointer or a slice, the caller keeps that memory alive for the documented lifetime. Borrowing does not by itself forbid allocation; a view that also promises not to allocate says so. The owning value copies what it retains and frees it in `deinit`. If construction fails after acquiring resources, release them before returning. `errdefer` is the usual tool. A cursor that cannot take the next bytes reports the error before those bytes are consumed.

Failure has defined semantics. An operation that promises atomicity, including an editing transaction, preserves its prior state when it returns an error. An operation that may make partial progress says how far it got, and what the caller must do next. Do not leave that implicit.

An object whose address is retained by callbacks, Lua upvalues or other instances is initialized in place or allocated at a stable address before those references are installed. Do not move it afterward. A value without such references may be returned by value; an owning value is not implicitly safe to copy.

Return a named error set, or the set inferred by `try`. Use `anyerror` only for a callback this code does not control, and name that function so the open set is obvious. `catch unreachable` and `@panic` mean this program is broken. A short file, a bad byte, or a full table is an operating error and returns. Exhaustion returns `error.OutOfMemory` or a domain error. An error is not discarded with `catch return` or an empty `catch`.

An invariant this program must uphold is `std.debug.assert`. Assert the case you expect. Where data is stored and later read back, check it on both sides. Split `assert(a and b)` into two asserts, so a failure names the clause. Do not assert a condition the caller can cause, and do not catch an assertion. There is no quota of asserts per function.

`unreachable` follows a local proof that the branch is empty, such as a switch arm already excluded by a range check. It is not a stand-in for an unlikely input. Some release modes delete it.

`index`, `count`, and `size` name different quantities even when they share a width. An index is 0-based, a count is how many, and a size is a count times a unit. Prefer `index < count` for the branch that means "inside." When rounding matters, use `@divFloor`, `@divExact`, or an explicit ceiling. Slice lengths stay `usize`. A count on a wire or in a file uses the width of that domain. `usize` is not a handle. Widths and non-exhaustive enums match the protocol, not a convenient machine word.

A loop ends because its structure ends: a counted `for`, a cursor that stops at `len`, or a walk whose depth the data already bounds. Add an explicit maximum only when termination is not structural, and then return or assert if it is hit. A loop that runs for the life of the process says so. Do not invent a limit the data cannot reach.

`undefined` fills storage the next lines overwrite, or poisons an object inside `deinit`. It is not a default for live state.

## Functions, control flow, and performance

A function does one phase a reviewer can name: parse a header, apply one edit, write one chunk. At about 70 lines, check whether the control flow still fits on a screen. The branches matter more than the count. A straight table of constants or build steps may be longer. A function that is already clear stays whole. Helpers that only forward arguments make it harder to follow.

When a split helps, keep the branches in the parent and move straight work into the helper. Pass a library option that selects a real behavior, such as endian, rounding, or an allocation limit. An empty options struct is right when every default is the one you mean.

Document whether a hot path allocates, locks or calls out, and preserve any explicit allocation-free contract. Rendering and input dispatch should reuse owned caches where practical. Keep setup and policy outside the inner loop. When changing hot-path work, state which resource it consumes and whether the cost is batched or paid per event. Changing a signature so that values stay in registers is a measured optimization, done when a profile says the current shape matters.

A capacity that is a design limit is a comptime config or a named constant, not a mutable global.

A multi-line `if` uses braces. A single-line `if (cond) assert(other);` is fine. Split a compound condition when a reader cannot see that every case was considered.

## Lua and native boundaries

Follow the existing Lua style: two-space indentation, `snake_case` functions and fields, local helpers and explicit module returns. Public command names and key sequences follow the registry's documented spelling. Keep the embedded defaults in `src/` and editable policy in `lua/` on the same API; share the mechanism rather than adding a privileged built-in path.

Treat Lua values and transport frames as boundary input. Validate types, ranges, UTF-8 and units before using them as native state. A borrowed Lua string lives only while its Lua value remains reachable; a decoded slice lives only as long as its frame storage. Copy data that must outlive either owner. State which object owns Lua registry references and when they are released. Balance the Lua stack on success and failure, and use protected calls for Lua callbacks.

Reload builds and validates a candidate VM, command registry and presentation before activation. A rejected candidate preserves the active VM and frame. Document state, sessions, undo history and native input state retain their own lifetimes. Lua is trusted code: arbitrary external side effects cannot be rolled back by discarding a VM. Presentation callbacks describe appearance; they do not mutate documents or receive native terminal objects. See [presentation](presentation.md), [keymaps](keymaps.md) and [minibuffer](minibuffer.md) contracts.

Transport validation includes framing, version, request identity and revision checks. A disconnected client and malformed request are operating conditions, not assertions. State what survives disconnect, which side owns cleanup and whether a failed request may already have taken effect. Never retry a mutation merely because its reply was lost.

## Testing, documentation, and workflow

Behavioral tests import the public module the way a caller would, and they live in `tests/`. A small test of a pure function may sit at the bottom of its file. When the tests outweigh the implementation, move them. A test name states one contract. A long test opens with a sentence on the goal and the method.

Use `std.testing.allocator` for Zig-managed allocations in tests. LuaJIT and other native allocations need their own lifetime checks. Exercise allocation failure for constructors, multi-step transactions, and any operation where a partial failure could break an invariant: a document left half-built, an undo entry without its inverse. A single obvious allocation does not need that treatment by default.

`zig build test` runs the Zig suite. `zig build check` compiles the editor and tests without running them. `zig build` produces the executable used by Python process and PTY tests. Format with `zig fmt`, and run `zig fmt --check` on the build files, `src`, and `tests` before the change is finished. Stay near 100 columns. A trailing comma on a multi-line list keeps later edits to one line. Break a long condition by hand when the formatted line is still hard to check.

Choose checks by the boundary changed. Zig tests cover host and bridge contracts. Python process tests cover daemon lifecycle and real transport; PTY tests cover input, visible rendering, resize and terminal restoration. Run the affected `tests/*_test.py` and `tests/*_terminal.py` scripts after building, and `tests/terminal.py` for general terminal behavior. A PTY check requires a controlling terminal; a sandbox denial is a validation limit, not a passing test. The README and feature documents list the relevant commands.

Python harnesses use `snake_case`, temporary working directories, isolated daemon endpoints and bounded waits for observable state. Reuse `daemon_support.py` and `terminal_support.py`. Clean up children, sockets and PTYs on failure as well as success. Do not depend on the user's running server or modify their configuration. A new test should exercise a contract through the real boundary it claims to cover.

`///` on a public declaration states the contract: ownership, units, what is preserved, what is rejected, and the failure behavior when it is not obvious. `//!` at the top of a file says what the file is for, in a line or two. A `//` comment states a constraint the types cannot express, as a sentence, and says why. It does not restate the next line. A design note lives in `docs/` only when a later edit would be wrong without it.

The README stays short and says how to fetch, build, test and format, with links to the relevant contract documents. Keep Markdown prose unwrapped; the column guideline applies to code. When behavior changes, update the comment or that document in the same change. History and measurements stay off the path a reader needs in order to edit a function.

`build.zig` declares modules, options, and steps. An option has a description. An optional feature has an explicit option and a working disabled configuration. A missing required dependency fails clearly. Use pinned package dependencies, not sibling checkouts or undeclared system installations. Keep unusual pin rationale beside the pin. The build does not search another tree and splice source into a generated file.

Native diagnostics use `std.log.scoped`; the host chooses enabled scopes and output. Interactive failures also reach the editor message or command result. Do not write diagnostics into terminal cells or a framed transport stream through an unrelated output path.

A reader of the diff should be able to answer, from the code, the doc comment, or the specification:

- Who allocates, and who frees?
- What input is rejected, and with which error?
- On failure, what happens to the values that were passed in?
- Which test fails if that contract regresses?

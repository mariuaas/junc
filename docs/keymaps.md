# Layered keymaps

Keymaps are Lua policy that selects commands from the live registry. Commands still run through the same Litura submission adapter. A map never owns a document, cursor or interaction session.

For a small live demonstration, open M-: and evaluate this statement:

```lua
editor.keymap('navigation', {
  j='down', k='up', ['g g']='buffer-start', escape='keymap.pop',
}, {priority=10}); editor.push_keymap('navigation')
```

Cancel the REPL with Ctrl-G. Now j/k navigate, g g moves to the beginning, and Escape deactivates navigation. Typing returns immediately to ordinary insertion. The document map remains active while you open M-x or M-:, but cannot intercept minibuffer input. Use M-x `describe-keymaps` to see active layers, or M-x `describe-keymap`, then complete `navigation`, to inspect its bindings. Redefine `navigation` with another `editor.keymap` call to change its bindings immediately while it remains active. No rebuild or reload is needed. To persist definitions and activations, put them inside the initializer returned by `lua/extension.lua`, then press Ctrl-R.

## Resolution and precedence

The focused surface determines which layers participate. There are currently two focus contexts: `document` and `minibuffer`. Command, Lua and generic prompt input all use the minibuffer context.

1. Transient maps for that context, ordered by descending numeric priority. The most recently pushed wins ties.
2. The context's selected map, initially `document` or `minibuffer`.
3. `global`, where `editor.bind` installs bindings.
4. Ordinary text insertion, if no layer recognized the event.

The tiers are fixed: a context map's numeric priority never puts it above a transient map. Numeric priority orders transient maps. A push can override the map's priority for that activation.

**The first layer that recognizes the first key owns the entire sequence.** A direct binding in a higher layer shadows a lower layer's whole prefix. A higher prefix also shadows lower direct bindings and lower prefixes, including their otherwise unique continuations. There is no merging of prefix branches or fallback midway through a sequence. This makes shadowing independent of which continuation happens to arrive.

Within one map, a key sequence cannot be both a command and a prefix. Defining `g` and `g g` together is an error, in either insertion order. The entire map replacement is compiled into a trie before publication; rejected definitions preserve the previous map, activations and pending sequence. `editor.bind` obeys the same rule for the global map. To replace a prefix with a direct global command, first remove its child bindings with `editor.bind(sequence, nil)`.

A prefix waits without a timeout and shows sorted immediate continuations in the status message, for example `g ... [navigation] g -> buffer-start`. Both shipped presentations include that message; custom status functions should include `state.message` to display hints and errors. Escape or Ctrl-G cancels a pending sequence and consumes the cancellation key. An invalid continuation cancels and consumes the whole sequence. Neither case executes a lower binding or inserts the continuation as text. A fresh key event then starts normal resolution. Thus Escape during `g ...` cancels first; another Escape can execute navigation's `keymap.pop`.

Focus changes cancel pending sequences. They retain transient activations, so returning from input resumes the document's layers. Defining a map, changing a context map, or pushing/popping a map also cancels the pending sequence. An unavailable command reports an error and consumes the binding; it never falls back to insertion.

## Defining and activating maps

```lua
editor.keymap('navigation', bindings, {priority=10})
editor.push_keymap('navigation')
editor.pop_keymap()

-- Opt in explicitly to a transient override of minibuffer input.
editor.push_keymap('input-override', {context='minibuffer', priority=20})
editor.pop_keymap{context='minibuffer'}

editor.set_context_keymap('document', 'source-editing')
editor.bind('ctrl-x ctrl-s', 'save')
editor.bind('ctrl-x ctrl-s', nil) -- Remove a global binding.
```

`keymap` replaces a named map's complete definition, copying bindings into a private trie. The priority defaults to zero and must be a finite integer. Active maps are referenced by name, so redefinition changes them immediately. A push without a priority override follows the map's current priority. `push_keymap` and `pop_keymap` default to the **document** context, including when called from the REPL. `pop_keymap` removes the highest-priority transient layer, with newest-first tie breaking, and returns its name or nil. A map cannot be pushed twice in the same context, or used as both its context and transient map. `global` remains the fallback and cannot be pushed or selected as a context map.

Bindings map canonical, space-separated event names to registered command names. Use `ctrl-x`, `alt-x`, `alt-colon`, `shift-left`, `escape`, `enter`, and literal printable characters such as `j` or `界`. Use `space` for a literal space. Native input names modifiers in ctrl/alt/shift order; unmodified printable characters retain their case. This interface does not parse Emacs notation such as `C-x` or raw terminal escape sequences. Terminal support determines which modified keys are distinguishable. Text chunks are not split into synthetic keystrokes; an unbound chunk inserts as ordinary text, while a chunk arriving during a pending prefix is consumed if it does not match a continuation.

Forward command references are allowed during definition, and whole-VM loading validates every map's command targets before activation. A live REPL binding to an unavailable command remains inspectable with `available=false` and reports an error on use. `editor.validate_keymaps()` can check those references explicitly. Binding tables and option tables must be plain tables; malformed sequences, values, priorities and unknown options are rejected before replacement.

The bundled global prefix examples are Ctrl-X Ctrl-S (save) and Ctrl-X Ctrl-R (reload). Existing single-key bindings remain. `buffer-start`, `buffer-end`, `keymap.pop`, `describe-keymap` and `describe-keymaps` are ordinary registry commands.

## Introspection

All queries return copied Lua tables, without native document handles or mutable references into the trie:

```lua
editor.keymap_names()                    -- Sorted names, optional prefix argument.
editor.keymap_info('navigation')          -- Priority, active flag and sorted bindings.
editor.keymap_state()                    -- Document layers, bindings and pending prefix.
editor.keymap_state('minibuffer')         -- Input layers, independently.
editor.command_info('buffer-start')      -- Includes map-qualified command bindings.
```

`keymap_state` contains `context`, actual `focused` context, ordered `layers`, all active `bindings`, and optional `pending`. Layers contain `name`, `kind` and `priority`. Binding rows contain `map`, `kind`, `sequence`, `command`, `available` and optional `shadowed_by`. Shadowing reports the higher map that owns the first key. `pending` contains the owning `map`, entered `sequence`, and sorted `continuations` with `key`, optional `command`, and boolean `prefix`. `keymap_info` describes inactive maps too and reports the definition's priority; active layers report any per-push priority override. `available` means the command exists in the Lua registry, not that every host effect is allowed in that context. Its active/shadowing fields refer to the requested context, which defaults to document.

`command_info.bindings` keeps global sequences unqualified and prefixes other bindings with the map name. It includes definitions in inactive maps; use `keymap_state` to see effective layers and shadowing. `editor.cancel_key_sequence()` clears a pending prefix and returns whether one existed.

## Focus, ownership and reload

Zig normalizes libvaxis events and supplies a snapshot for the focused Litura target. Lua resolves the trie and invokes the existing command registry. Zig applies returned text/history/interaction intents, measures cells and renders. The minibuffer's submission, cancellation, completion and history choices are bindings in its Lua context map. Their commands call the native `editor.input_action(action)` facade (`submit`, `cancel`, `complete`, `previous`, `next`); Zig retains ownership of input documents, completion strings and history. These actions require a focused minibuffer and explicit command evaluation. Ordinary editing commands use the same bridge on either surface. Save and quit through ordinary minibuffer key dispatch remain unavailable; explicit REPL `editor.invoke` calls continue to target the main document.

Ctrl-R stages the entire replacement VM, including maps, commands and presentation. Invalid definitions or unresolved command targets reject the replacement and retain the previous VM, maps, activations and pending prefix. A successful reload activates the candidate's configured layers and clears pending input sequences. Temporary REPL map definitions and pushes are lost, just like temporary commands and globals. The two Litura documents, sessions, selections, revisions, undo histories and native minibuffer histories remain alive. As before, a generic prompt cancels when its VM-owned callback is replaced.

There are no modes, repeat counts, prefix arguments, key-sequence timeouts or inherited Emacs/Vim semantics. The mechanism supplies map composition and command selection; Lua can build more involved interactions later.

`zig build test` covers priority, recency, context fallback, direct/prefix shadowing, deep prefixes, invalid and cancelled sequences, copied introspection, Unicode, unavailable commands and atomic replacement/reload. `python3 tests/keymap_terminal.py` demonstrates the navigation map through the live REPL, M-x inspection, which-key feedback, resize, Unicode and Meta events, reload, undo and terminal restoration.

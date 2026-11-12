# Minibuffer and live Lua

M-x runs a named command; M-: evaluates Lua in the running editor. Both use the minibuffer, a separate input document at the bottom of the terminal, so editing a prompt leaves the file untouched. Meta means Alt when the terminal sends that modifier, or Escape followed promptly by x or colon. If your terminal or multiplexer intercepts Meta, use Ctrl-O for commands and Ctrl-L for Lua. All bindings use normalized libvaxis events.

| Key while input is focused | Action |
| --- | --- |
| Enter | Submit to the active context |
| Escape / Ctrl-G | Cancel and return to the document |
| Tab | Complete a prefix; repeat to cycle ambiguous matches |
| Up / Down | Cycle active completions, otherwise navigate this context's history |
| Left / Right, Home / End, C-f / C-b, C-n / C-p, C-a / C-e, C-v / M-v | Move by grapheme, line or screenful |
| Shift plus a movement key, Ctrl-X h | Extend selection, or select all |
| M-p / M-n | Cycle this context's history, like Up / Down |
| Backspace / Delete, Ctrl-Z / Ctrl-Y | Edit input, undo / redo input edits |
| Shift-Enter | Insert a newline, if the terminal reports that modifier |
| Ctrl-R | Reload commands and presentation while retaining input |

The [Lua minibuffer context map](keymaps.md) defines input bindings. Document transient maps do not participate in its resolution; minibuffer transients require an explicit context option.

Typing and ordinary editing commands target the focused input document, never the underlying file. Save, quit and presentation shell intents are unavailable through ordinary input key dispatch; cancel input first to use their document bindings. Explicit Lua `editor.invoke` calls target the selected main document. Opening either built-in context starts with empty input; history and the underlying input document/session survive closing it.

The bottom region has one editable row and up to two completion or output rows. For multiline input it displays the cursor's current line. Layout, Unicode widths, selection, clipping and the software cursor use the same renderer as the selected main document. Very small terminals prioritize the editable row. The minibuffer uses the active theme and optional [minibuffer colors](presentation.md).

## Commands

M-x discovers the current `editor.commands` registry, including commands added by extensions or the REPL. Type a prefix and press Tab. A unique match replaces the input; ambiguous matches extend the common prefix, then Tab or Up/Down cycles them. Enter executes the input's exact command name through the same Lua dispatch and Litura intent adapter as a keybinding. An unknown command leaves the input available for correction.

Run `describe-command` through M-x, complete another command name, and submit. The description includes optional metadata and all current bindings. Command output appears in the status message when input closes and remains in the output history, visible when input opens again. Commands and bindings are separate: an unbound command remains discoverable and executable.

An extension can supply metadata without changing the original two-argument API:

```lua
editor.command('stamp', function(context)
  return editor.replace(context, 'hello')
end, {description='Insert a greeting', category='example'})
editor.bind('ctrl-t', 'stamp')
```

## Live Lua

M-: evaluates in the active LuaJIT VM, so a command or binding you define is immediately available to the editor. It first tries Lua's expression parser, then its statement parser. Multiple return values, including nil, are displayed; statements with no results show `(no values)`. Tables get a small readable preview. `print` writes to the bounded output history. Parser errors and runtime errors appear there without ending the session. Lua has the standard libraries and FFI. Evaluation can affect files, processes and editor state, and it can block the editor; use it as trusted code.

Try each line separately:

```lua
editor.command_names()
editor.command_info('save')
editor.state().revision
editor.command('greet', function(c) return editor.replace(c, 'hello') end)
editor.bind('ctrl-t', 'greet')
editor.invoke('greet')
```

Cancel input, then press Ctrl-T to use the new command. `editor.invoke(name, optional_text)` returns a submission summary containing `kind`, `revision` and `interaction_revision`, or true for a command without a returned intent. Errors are raised as ordinary Lua errors. Replacing a command with another `editor.command` call takes effect immediately. `editor.state()` returns a copied main-document command snapshot; it exposes no native document pointer. Both invocation and key dispatch use the established public Litura submission bridge.

## Generic prompts

A command can use the same input surface to request a value. Completion returns an array of strings; the shared completion layer filters prefixes, deduplicates and sorts. `submit` receives the exact input string. Callback errors leave the input editable.

```lua
editor.prompt{
  label='Greeting: ', history='greeting', initial='',
  complete=function(prefix) return {'hello', 'hi', 'welcome'} end,
  submit=function(value) editor.invoke('insert', value) end,
}
```

The label is printable UTF-8 shorter than 128 bytes. The history namespace is nonempty printable UTF-8 shorter than 64 bytes. Completion candidates must be printable single-line UTF-8. Completion providers should be observational; an explicit `editor.invoke` is required to perform an edit. A prompt may open another prompt from its submit callback. There is one active context, without nested prompt stacks.

History lives in Zig, with 50 entries shared across namespaces; entries over 64 KiB are not retained. Up/Down restores the draft when returning past the newest entry. Command input, Lua input and generic prompts have separate namespaces. Lua Tab completion uses single-line history; multiline entries remain available through Up/Down. Completion displays at most 256 candidates. Output retains eight entries, each clipped at a grapheme boundary to 4096 bytes with control characters replaced for display. There is no persistence to disk or output scrollback UI yet.

## Reload and ownership

Ctrl-R builds a replacement Lua VM and activates it only after the registry, extension and presentation load and validate. A rejected reload retains the active VM, temporary definitions, callbacks and input. A successful reload discards temporary globals, commands, bindings, transient map activations and Lua prompt callbacks, replacing them with the candidate configuration. It cancels pending key sequences. Command and Lua contexts keep their input, cursor and selection; a generic prompt is cancelled because its callback belongs to the retired VM. The hosted Litura buffers, their sessions, revisions, selections and undo histories stay alive, along with the local minibuffer, native history and output. Reload requested from Lua is deferred until the active command, REPL or observer callback returns, so it never destroys an executing VM.

The client minibuffer owns a separate persistent Litura document and interaction session; main documents and their sessions live in the [local server](daemon.md). Shared editing primitives and `BufferEngine.submit` handle its text, selections and cursor. Native history and completion replacements also use revision-aware submission, without moving anchors directly. Command snapshots and result observers include `surface`, either `document` or `minibuffer`, so observers can distinguish their revision domains. Opening, editing and cancelling input do not change main-document revisions or undo history. Presentation callbacks cannot invoke the native editing bridge; explicit command evaluation is required. The [Lua API](lua-api.md) describes which submissions the observer sees and which parts of Litura’s reflection contract remain unsupported.

`zig build test` checks editing isolation, Unicode cells, registry discovery, invocation, Lua evaluation, errors, history, generic prompts and reload lifetime. `python3 tests/minibuffer_terminal.py` exercises real Meta input and fallbacks, completion, live definitions and bindings, Lua errors, resize down to one cell, failed and successful reload, undo and terminal restoration.

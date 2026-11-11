//! Explicit focus routing and submission policy for one persistent input surface.
const Editor = @import("Editor.zig");
const runtime = @import("runtime.zig");

pub const Action = enum { cancel, complete, previous, next, submit };

/// Performs an input action selected by Lua's focused context map. Editing stays in the shared bridge.
pub fn perform(editor: *Editor, action: Action) !void {
    const mini = &editor.minibuffer;
    switch (action) {
        .cancel => try editor.cancelMinibuffer(),
        .complete => try runtime.complete(editor),
        .previous, .next => {
            if (mini.candidates.items.len > 0) {
                try mini.cycleCandidate(action == .previous);
            } else try mini.navigateHistory(action == .previous);
        },
        .submit => try submit(editor),
    }
}

fn submit(editor: *Editor) !void {
    const mini = &editor.minibuffer;
    const context = mini.context orelse return;
    const source = try mini.document.getText();
    defer editor.allocator.free(source);
    try mini.remember(source);
    mini.clearCandidates();
    mini.resetNavigation();
    switch (context) {
        .command => {
            // Close first: a chosen command may open a new, generic prompt.
            try editor.cancelMinibuffer();
            const result = editor.invoke(source, "") catch |err| {
                mini.context = .command;
                try editor.syncKeyContext();
                try mini.appendOutput(if (err == error.LuaError) editor.status() else @errorName(err));
                return;
            };
            if (result) |value| {
                var owned = value;
                defer owned.deinit(editor.allocator);
                if (owned == .validation_report) {
                    mini.context = .command;
                    try editor.syncKeyContext();
                    try mini.appendOutput(owned.validation_report.message);
                }
            }
        },
        .lua => {
            try runtime.evaluate(editor, source);
            // An evaluation may open a prompt or switch focus; do not reset its new input.
            if (mini.context == .lua) try mini.setText("");
        },
        .prompt => {
            try editor.cancelMinibuffer();
            if (!try runtime.submitPrompt(editor, source) and mini.context == null) {
                mini.context = .prompt;
                try editor.syncKeyContext();
            }
        },
    }
}

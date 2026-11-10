-- Presentation policy. No document mutation API is exposed to these callbacks.
local function classic_status(s)
  return string.format(' junc | %s%s | %d:%d r%d i%d | %s | ^P minimal ^R reload',
    s.path, s.dirty and ' *' or '', s.line, s.column,
    s.revision, s.interaction_revision, s.message)
end
return {
  default = 'classic',
  next = function(name) return name == 'classic' and 'minimal' or 'classic' end,
  presets = {
    classic = {
      theme = function(t)
        return {fg=t.foreground, bg=t.background,
          selection_fg='#ffffff', selection_bg=t.palette[4],
          cursor_fg=t.background ~= 'default' and t.background or 0,
          cursor_bg=t.foreground ~= 'default' and t.foreground or 7,
          gutter_fg=t.palette[8], gutter_bg=t.background,
          status_fg=t.background ~= 'default' and t.background or 0,
          status_bg=t.foreground ~= 'default' and t.foreground or 7}
      end,
      gutter = {visible=true, line_numbers=true},
      status_visible = true,
      status = classic_status,
    },
    minimal = {
      theme = function(t)
        return {fg='#c8d5c8', bg='#18221e',
          selection_fg='#18221e', selection_bg='#b8ce9a',
          cursor_fg='#18221e', cursor_bg='#edcf8e',
          gutter_fg='#718779', gutter_bg='#18221e',
          status_fg='#94aa99', status_bg='#18221e'}
      end,
      gutter = {visible=false, line_numbers=false},
      status_visible = true,
      status = function(s)
        return string.format(' %s%s  %d:%d  %s', s.path, s.dirty and ' +' or '',
          s.line, s.column, s.message)
      end,
    },
  },
}

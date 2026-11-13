-- Shell registry: commands return intents; the host submits them to Litura.
local install_keymaps = ...
local M = {commands = {}, metadata = {}}
install_keymaps(M)
function M.on_result(result) M.last_result = result end
function M.command(name, fn, metadata)
  assert(type(name)=='string' and type(fn)=='function', 'command requires a name and function')
  assert(metadata==nil or type(metadata)=='table', 'metadata must be a table')
  if metadata then
    assert(metadata.description==nil or type(metadata.description)=='string', 'description must be a string')
    assert(metadata.category==nil or type(metadata.category)=='string', 'category must be a string')
  end
  M.commands[name] = fn
  M.metadata[name] = metadata or {}
end
function M.command_names(prefix)
  prefix = prefix or ''
  local names = {}
  for name, fn in pairs(M.commands) do
    if type(fn)=='function' and name:sub(1,#prefix)==prefix then names[#names+1]=name end
  end
  table.sort(names)
  return names
end
function M.command_info(name)
  if type(M.commands[name])~='function' then error('Unknown command: '..name) end
  local metadata = M.metadata[name] or {}
  return {name=name, description=metadata.description or '', category=metadata.category or '',
    bindings=M.command_bindings(name)}
end
function M.execute(name, c, text)
  local fn = M.commands[name]
  if type(fn)~='function' then error('Unknown or unavailable command: '..tostring(name)) end
  local intent = fn(c, text or '')
  if intent then
    intent.source = name
    -- Preserve an explicitly captured origin; defaults refer to this command's observation.
    if intent.origin==nil then intent.origin=c.revision end
    if intent.interaction_origin==nil then intent.interaction_origin=c.interaction_revision end
    if intent.buffer_id==nil then intent.buffer_id=c.buffer_id end
  end
  return intent
end
-- Map an ordinary per-cursor intent into one atomic batch. Context origins stay at the observation.
function M.each(c, fn)
  if not c.selections or #c.selections<=1 then return fn(c) end
  local edits = {}
  for _, selection in ipairs(c.selections) do
    local one = {}
    for k,v in pairs(c) do if k~='selections' then one[k]=v end end
    for k,v in pairs(selection) do one[k]=v end
    local action = fn(one) or {kind='keep'}
    assert(action.origin==nil or action.origin==c.revision, 'Mixed document origins')
    assert(action.interaction_origin==nil or action.interaction_origin==c.interaction_revision,
      'Mixed interaction origins')
    assert(action.buffer_id==nil or action.buffer_id==c.buffer_id, 'Mixed buffer identities')
    action.cursor_anchor = selection.cursor_anchor
    edits[#edits+1] = action
  end
  return {kind='batch', edits=edits, origin=c.revision,
    interaction_origin=c.interaction_revision, buffer_id=c.buffer_id}
end
function M.replace(c, text, first, last)
  if first==nil and last==nil and c.selections and #c.selections>1 then
    return M.each(c, function(one) return M.replace(one, text) end)
  end
  return {kind='replace', start=first or c.first, finish=last or c.last, text=text,
    origin=c.revision, interaction_origin=c.interaction_revision, buffer_id=c.buffer_id}
end
function M.move(c, position, select)
  return {kind='move', position=position, mark=select and (c.mark or c.cursor) or nil,
    origin=c.revision, interaction_origin=c.interaction_revision, buffer_id=c.buffer_id}
end
M.command('insert', function(c, text) return M.replace(c, text) end)
M.command('paste', function(c, text)
  if text=='' then return end
  M.cancel_key_sequence()
  return M.replace(c, (text:gsub('\r\n','\n'):gsub('\r','\n')))
end, {description='Insert pasted text as one edit', category='editing'})
M.command('backspace', function(c) return M.each(c, function(c)
  if c.first ~= c.last then return M.replace(c, '') end
  if c.cursor > 0 then return M.replace(c, '', c.cursor-1, c.cursor) end
end) end)
M.command('delete', function(c) return M.each(c, function(c)
  if c.first ~= c.last then return M.replace(c, '') end
  if c.cursor < c.count then return M.replace(c, '', c.cursor, c.cursor+1) end
end) end)
M.command('enter', function(c) return M.replace(c, '\n') end)
M.command('tab', function(c) return M.replace(c, '\t') end)
for _, direction in ipairs({'left','right','up','down','home','end'}) do
  local d = direction
  M.command(d, function(c) return M.each(c, function(one) return M.move(one, one[d]) end) end)
  M.command('select-'..d, function(c) return M.each(c, function(one) return M.move(one, one[d], true) end) end)
  M.bind(d, d); M.bind('shift-'..d, 'select-'..d)
end
M.command('select-all', function(c)
  if c.surface=='minibuffer' then return {kind='move',position=c.count,mark=0} end
  return {kind='selections', edits={
    {kind='move', cursor_anchor=c.cursor_anchor, position=c.count, mark=0}}}
end)
for _, name in ipairs({'quit','reload','undo','redo'}) do
  local n = name
  M.command(n, function() return {kind=n} end)
end
M.command('save', function(c)
  if c.surface=='document' and not c.path then
    M.invoke('save-as')
    return
  end
  return {kind='save'}
end)
M.bind('backspace','backspace'); M.bind('delete','delete'); M.bind('enter','enter'); M.bind('tab','tab')
M.bind('ctrl-s','save'); M.bind('ctrl-q','quit'); M.bind('ctrl-r','reload')
M.bind('ctrl-z','undo'); M.bind('ctrl-y','redo')
M.bind('ctrl-w','wrap')
M.command('presentation-next', function(c)
  return {kind='presentation', name=presentation.next(c.presentation)}
end)
M.metadata.insert = {description='Replace the selection with input text', category='editing'}
M.metadata.save = {description='Save the current document', category='file'}
M.metadata.reload = {description='Reload Lua commands and presentation', category='runtime'}
M.metadata.undo = {description='Undo the last document edit', category='editing'}
M.metadata.redo = {description='Redo the last undone edit', category='editing'}
M.command('execute-command', function() return {kind='minibuffer', context='command'} end,
  {description='Execute a command from the live registry', category='runtime'})
M.command('lua-repl', function() return {kind='minibuffer', context='lua'} end,
  {description='Evaluate Lua in the live environment', category='runtime'})
M.command('describe-command', function()
  M.prompt{label='Describe command: ', history='describe-command', complete=M.command_names,
    submit=function(name)
      local info = M.command_info(name)
      M.output(info.name..' ['..info.category..'] '..info.description..' | '..table.concat(info.bindings, ', '))
    end}
end, {description='Describe a registered command and its bindings', category='help'})
M.bind('alt-x', 'execute-command'); M.bind('ctrl-o', 'execute-command')
M.bind('alt-colon', 'lua-repl'); M.bind('ctrl-l', 'lua-repl')
M.command('buffer-start', function(c) return M.each(c, function(one) return M.move(one, 0) end) end)
M.command('buffer-end', function(c) return M.each(c, function(one) return M.move(one, c.count) end) end)
M.command('forward-char', M.commands.right, {description='Move one grapheme forward', category='motion'})
M.command('backward-char', M.commands.left, {description='Move one grapheme backward', category='motion'})
M.command('next-line', M.commands.down, {description='Move to the same column on the next line', category='motion'})
M.command('previous-line', M.commands.up, {description='Move to the same column on the previous line', category='motion'})
M.command('beginning-of-line', M.commands.home, {description='Move to the start of the current line', category='motion'})
M.command('end-of-line', M.commands['end'], {description='Move to the end of the current line', category='motion'})
M.command('beginning-of-buffer', M.commands['buffer-start'], {description='Move to the start of the buffer', category='motion'})
M.command('end-of-buffer', M.commands['buffer-end'], {description='Move to the end of the buffer', category='motion'})
local function page(c, position, top, extend)
  if c.surface=='document' then M.scroll(top) end
  return M.each(c, function(one)
    return M.move(one, math.max(0,math.min(c.count,one.cursor+position-c.cursor)), extend)
  end)
end
M.command('page-down', function(c) return page(c, c.page_down, c.page_down_top) end,
  {description='Move down by one screen, keeping the cursor in the window', category='motion'})
M.command('page-up', function(c) return page(c, c.page_up, c.page_up_top) end,
  {description='Move up by one screen, keeping the cursor in the window', category='motion'})
M.command('select-page-down', function(c) return page(c, c.page_down, c.page_down_top, true) end)
M.command('select-page-up', function(c) return page(c, c.page_up, c.page_up_top, true) end)
M.command('scroll-up', M.commands['page-down'], {description='Emacs name for page-down', category='motion'})
M.command('scroll-down', M.commands['page-up'], {description='Emacs name for page-up', category='motion'})
M.command('delete-char', M.commands.delete, {description='Delete the next grapheme, or the selection', category='editing'})
local function add_cursor(c, direction)
  local edits, seen = {}, {}
  for _, one in ipairs(c.selections) do
    edits[#edits+1]={kind='move', cursor_anchor=one.cursor_anchor, position=one.cursor, mark=one.mark}
    seen[one.cursor]=true
  end
  for _, one in ipairs(c.selections) do
    local at = one[direction]
    if not seen[at] then edits[#edits+1]={kind='move',position=at}; seen[at]=true end
  end
  return {kind='selections', edits=edits}
end
M.command('cursor-add-above', function(c) return add_cursor(c,'up') end,
  {description='Add a cursor on the preceding line', category='selection'})
M.command('cursor-add-below', function(c) return add_cursor(c,'down') end,
  {description='Add a cursor on the following line', category='selection'})
M.command('cursor-add-next', function() return {kind='add_next'} end,
  {description='Select the word, then add its next exact occurrence', category='selection'})
M.command('cursor-single', function(c)
  return {kind='selections', edits={{kind='move',cursor_anchor=c.cursor_anchor,position=c.cursor,mark=c.mark}}}
end, {description='Keep only the primary cursor', category='selection'})
M.bind('ctrl-x up','cursor-add-above'); M.bind('ctrl-x down','cursor-add-below')
M.bind('ctrl-x d','cursor-add-next'); M.bind('ctrl-x 1','cursor-single')
M.command('keyboard-quit', function()
  M.cancel_key_sequence()
  return {kind='key-feedback', message='Quit'}
end, {description='Cancel a pending key sequence', category='runtime'})
M.command('keymap.pop', function(c)
  local name=M.pop_keymap{context=c.surface}
  return {kind='key-feedback', message=name and ('Popped '..name) or 'No transient keymap'}
end, {description='Deactivate the highest-priority transient map in this context', category='keymap'})
M.command('describe-keymaps', function(c)
  local names={}
  for _, layer in ipairs(M.keymap_state(c.surface).layers) do
    names[#names+1]=layer.name..' ['..layer.kind..':'..layer.priority..']'
  end
  M.output(c.surface..': '..table.concat(names,' > '))
end, {description='Show active keymap layers in priority order', category='keymap'})
M.command('describe-keymap', function(c)
  local context=c.surface
  M.prompt{label='Describe keymap: ', history='describe-keymap', complete=M.keymap_names,
    submit=function(name)
      local info, entries=M.keymap_info(name, context), {}
      for _, binding in ipairs(info.bindings) do
        entries[#entries+1]=binding.sequence..' -> '..binding.command..
          (binding.shadowed_by and (' [shadowed by '..binding.shadowed_by..']') or '')
      end
      M.output(name..(info.active and ' [active] ' or ' [inactive] ')..table.concat(entries,' | '))
    end}
end, {description='Describe bindings and shadowing in a named keymap', category='keymap'})
for _, action in ipairs({'cancel','submit','complete','previous','next'}) do
  local a=action
  M.command('minibuffer.'..a, function() M.input_action(a) end)
end
M.keymap('emacs', {
  ['ctrl-f']='forward-char', ['ctrl-b']='backward-char',
  ['ctrl-n']='next-line', ['ctrl-p']='previous-line',
  ['ctrl-a']='beginning-of-line', ['ctrl-e']='end-of-line',
  ['ctrl-v']='page-down', ['alt-v']='page-up',
  ['ctrl-d']='delete-char', ['ctrl-g']='keyboard-quit',
  ['ctrl-shift-f']='select-right', ['ctrl-shift-b']='select-left',
  ['ctrl-shift-n']='select-down', ['ctrl-shift-p']='select-up',
  ['ctrl-shift-a']='select-home', ['ctrl-shift-e']='select-end',
  ['ctrl-shift-v']='select-page-down', ['alt-shift-v']='select-page-up',
  ['alt-<']='beginning-of-buffer', ['alt-shift-<']='beginning-of-buffer',
  ['alt->']='end-of-buffer', ['alt-shift->']='end-of-buffer',
})
M.set_context_keymap('document', 'emacs')
M.keymap('minibuffer', {
  escape='minibuffer.cancel', ['ctrl-g']='minibuffer.cancel', enter='minibuffer.submit',
  tab='minibuffer.complete', up='minibuffer.previous', down='minibuffer.next',
  ['alt-p']='minibuffer.previous', ['alt-n']='minibuffer.next', ['shift-enter']='enter',
  ['ctrl-f']='forward-char', ['ctrl-b']='backward-char',
  ['ctrl-n']='next-line', ['ctrl-p']='previous-line',
  ['ctrl-a']='beginning-of-line', ['ctrl-e']='end-of-line', ['ctrl-d']='delete-char',
  ['ctrl-v']='page-down', ['alt-v']='page-up',
  ['alt-<']='beginning-of-buffer', ['alt-shift-<']='beginning-of-buffer',
  ['alt->']='end-of-buffer', ['alt-shift->']='end-of-buffer',
})
M.bind('page-down', 'page-down'); M.bind('page-up', 'page-up')
M.bind('shift-page-down', 'select-page-down'); M.bind('shift-page-up', 'select-page-up')
M.bind('ctrl-x ctrl-s', 'save')
M.bind('ctrl-x ctrl-r', 'reload')
M.bind('ctrl-x ctrl-p', 'presentation-next')
M.bind('ctrl-x h', 'select-all')
local function buffer_candidates()
  local entries={}
  local current=M.state().buffer_id
  for _, buffer in ipairs(M.buffers()) do
    entries[#entries+1]=string.format('%d %s%s%s', buffer.id, buffer.name,
      buffer.id==current and ' [current]' or '', buffer.dirty and ' *' or '')
  end
  return entries
end
local function switch_prompt(show)
  M.prompt{label='Buffer: ',history='switch-buffer',complete=buffer_candidates,
    submit=function(value)
      local id=tonumber(value:match('^(%d+)'))
      assert(id, 'Choose a buffer id from completion')
      M.select_buffer(id)
    end}
  if show then M.input_action('complete') end
end
M.command('open-file', function()
  M.prompt{label='Open file (empty for scratch): ',history='open-file',submit=M.open_file}
end, {description='Open a file in the global registry, or create scratch input',category='buffer'})
M.command('switch-buffer', function() switch_prompt(false) end,
  {description='Select a global buffer with completion',category='buffer'})
M.command('list-buffers', function() switch_prompt(true) end,
  {description='Browse the global buffer registry; Enter selects',category='buffer'})
M.command('kill-buffer', function(c)
  for _, buffer in ipairs(M.buffers()) do
    if buffer.id==c.buffer_id then
      if buffer.dirty then
        M.prompt{label='Discard '..buffer.name..'? type yes: ',history='kill-buffer',submit=function(value)
          assert(value=='yes', 'Buffer retained; type yes to discard, or cancel')
          M.kill_buffer(buffer.id,true)
        end}
      else M.kill_buffer(buffer.id) end
      return
    end
  end
  error('Buffer is no longer available')
end, {description='Kill the current buffer; dirty contents require explicit confirmation',category='buffer'})
M.command('save-as', function()
  M.prompt{label='Save as: ',history='save-as',submit=function(path)
    assert(#path>0,'A filename is required'); M.save_as(path)
  end}
end, {description='Save under a filename, preserving global path uniqueness',category='file'})
M.command('shutdown-server', function() M.shutdown_server() end,
  {description='Stop a clean server and detach; refuses dirty buffers',category='runtime'})
return M

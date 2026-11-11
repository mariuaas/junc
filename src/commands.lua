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
  if intent then intent.source = name end
  return intent
end
function M.replace(c, text, first, last)
  return {kind='replace', start=first or c.first, finish=last or c.last, text=text}
end
function M.move(c, position, select)
  return {kind='move', position=position, mark=select and (c.mark or c.cursor) or nil}
end
M.command('insert', function(c, text) return M.replace(c, text) end)
M.command('backspace', function(c)
  if c.first ~= c.last then return M.replace(c, '') end
  if c.cursor > 0 then return M.replace(c, '', c.cursor-1, c.cursor) end
end)
M.command('delete', function(c)
  if c.first ~= c.last then return M.replace(c, '') end
  if c.cursor < c.count then return M.replace(c, '', c.cursor, c.cursor+1) end
end)
M.command('enter', function(c) return M.replace(c, '\n') end)
M.command('tab', function(c) return M.replace(c, '\t') end)
for _, direction in ipairs({'left','right','up','down','home','end'}) do
  local d = direction
  M.command(d, function(c) return M.move(c, c[d]) end)
  M.command('select-'..d, function(c) return M.move(c, c[d], true) end)
  M.bind(d, d); M.bind('shift-'..d, 'select-'..d)
end
M.command('select-all', function(c) return {kind='move', position=c.count, mark=0} end)
for _, name in ipairs({'save','quit','reload','undo','redo'}) do
  local n = name
  M.command(n, function() return {kind=n} end)
end
M.bind('backspace','backspace'); M.bind('delete','delete'); M.bind('enter','enter'); M.bind('tab','tab')
M.bind('ctrl-s','save'); M.bind('ctrl-q','quit'); M.bind('ctrl-r','reload')
M.bind('ctrl-a','select-all'); M.bind('ctrl-z','undo'); M.bind('ctrl-y','redo')
M.bind('ctrl-w','wrap')
M.command('presentation-next', function(c)
  return {kind='presentation', name=presentation.next(c.presentation)}
end)
M.bind('ctrl-p', 'presentation-next')
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
M.command('buffer-start', function(c) return M.move(c, 0) end)
M.command('buffer-end', function(c) return M.move(c, c.count) end)
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
M.keymap('minibuffer', {
  escape='minibuffer.cancel', ['ctrl-g']='minibuffer.cancel', enter='minibuffer.submit',
  tab='minibuffer.complete', up='minibuffer.previous', down='minibuffer.next', ['shift-enter']='enter',
})
M.bind('ctrl-x ctrl-s', 'save')
M.bind('ctrl-x ctrl-r', 'reload')
return M

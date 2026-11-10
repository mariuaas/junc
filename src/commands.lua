-- Shell registry: commands return intents; the host submits them to Litura.
local M = {commands = {}, keys = {}}
function M.on_result(result) M.last_result = result end
function M.command(name, fn) M.commands[name] = fn end
function M.bind(key, name) M.keys[key] = name end
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
function M.dispatch(key, c, text)
  local name = M.keys[key] or (text ~= '' and 'insert')
  if name and M.commands[name] then
    local intent = M.commands[name](c, text)
    if intent then intent.source = name end
    return intent
  end
end
return M

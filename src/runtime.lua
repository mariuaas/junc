-- The live facade delegates mutations to the same command bridge as keybindings.
return function(editor)
  local function checked(result, err)
    if err then error(err, 3) end
    return result
  end
  function editor.invoke(name, text) return checked(editor._invoke(name, text or '')) end
  function editor.input_action(action) return checked(editor._input_action(action)) end
  function editor.state() return checked(editor._state()) end
  function editor.output(text) return checked(editor._output(tostring(text))) end
  function editor.prompt(options)
    assert(type(options)=='table' and type(options.submit)=='function', 'prompt requires submit(value)')
    assert(options.complete==nil or type(options.complete)=='function', 'complete must be a function')
    local previous = editor.active_prompt
    editor.active_prompt = options
    local ok, err = editor._prompt(options.label or 'Value: ', options.history or 'prompt', options.initial or '')
    if err then editor.active_prompt=previous; error(err,2) end
    return ok
  end
  function editor.completions(kind, prefix, history)
    local values
    if kind=='command' then values=editor.command_names(prefix)
    elseif kind=='lua' then values=history
    else
      local prompt=assert(editor.active_prompt, 'Prompt is no longer available')
      values=prompt.complete and prompt.complete(prefix) or {}
    end
    assert(type(values)=='table', 'Completion must return an array')
    local matches, seen = {}, {}
    for _, value in ipairs(values) do
      assert(type(value)=='string', 'Completion candidates must be strings')
      if value:sub(1,#prefix)==prefix and not seen[value] then
        seen[value]=true; matches[#matches+1]=value
      end
    end
    table.sort(matches)
    return matches
  end
  local function display(value, depth)
    if type(value)~='table' then return tostring(value) end
    if depth==0 then return '{...}' end
    local keys={}
    for key in pairs(value) do keys[#keys+1]=key end
    table.sort(keys, function(a,b) return tostring(a)<tostring(b) end)
    local parts={}
    for i=1,math.min(#keys,16) do
      local key=keys[i]
      parts[#parts+1]=tostring(key)..'='..display(value[key],depth-1)
    end
    if #keys>16 then parts[#parts+1]='...' end
    return '{'..table.concat(parts,', ')..'}'
  end
  local function results(...)
    local values={}
    for i=1,select('#',...) do values[i]=display(select(i,...),2) end
    return #values>0 and table.concat(values,'    ') or '(no values)'
  end
  function editor.eval(source)
    local chunk, err=loadstring('return '..source, '=minibuffer')
    if not chunk then chunk,err=loadstring(source, '=minibuffer') end
    if not chunk then error(err,0) end
    return results(chunk())
  end
  function print(...) editor.output(results(...)) end
end

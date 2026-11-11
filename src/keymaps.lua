-- Key selection policy lives in this VM; tries select commands without touching documents.
return function(editor)
  local maps, contexts = {}, {document='document', minibuffer='minibuffer'}
  local stacks = {document={}, minibuffer={}}
  local focused, pending = 'document', nil

  local function scope(context)
    if context==nil then context='document' end
    assert(stacks[context], 'Unknown keymap context: '..tostring(context))
    return context
  end
  local function priority(value)
    if value==nil then value=0 end
    assert(type(value)=='number' and value==value and math.abs(value)<math.huge
      and math.floor(value)==value, 'Keymap priority must be a finite integer')
    return value
  end
  local function options(value, allowed)
    if value==nil then value={} end
    assert(type(value)=='table' and getmetatable(value)==nil, 'Keymap options must be a plain table')
    for key in pairs(value) do assert(allowed[key], 'Unknown keymap option: '..tostring(key)) end
    return value
  end
  local function tokens(sequence)
    assert(type(sequence)=='string' and not sequence:find('[%z\1-\31\127]'), 'Invalid key sequence')
    local result={}
    for key in sequence:gmatch('%S+') do result[#result+1]=key end
    assert(#result>0 and table.concat(result,' ')==sequence, 'Use space-separated key names')
    for i=2,#result do
      assert(result[i]~='escape' and result[i]~='ctrl-g', 'Escape and ctrl-g cancel pending prefixes')
    end
    return result
  end
  local function compile(bindings)
    assert(type(bindings)=='table' and getmetatable(bindings)==nil, 'Bindings must be a plain table')
    local root, copy = {children={}}, {}
    for sequence, command in pairs(bindings) do
      assert(type(command)=='string' and #command>0, 'Binding requires a command name')
      local node = root
      for _, key in ipairs(tokens(sequence)) do
        assert(not node.command, 'Command overlaps a prefix: '..sequence)
        node.children[key] = node.children[key] or {children={}}
        node = node.children[key]
      end
      assert(not next(node.children), 'Command overlaps a prefix: '..sequence)
      node.command = command
      copy[sequence] = command
    end
    return root, copy
  end
  function editor.keymap(name, bindings, config)
    assert(type(name)=='string' and #name>0 and not name:find('[%c%s]'), 'Invalid keymap name')
    config = options(config, {priority=true})
    local rank = priority(config.priority)
    local root, copy = compile(bindings)
    -- Publish only after the entire replacement has compiled successfully.
    maps[name] = {root=root, bindings=copy, priority=rank}
    pending = nil
  end
  function editor.bind(sequence, command)
    local bindings={}
    for key, value in pairs(maps.global.bindings) do bindings[key]=value end
    bindings[sequence]=command -- nil removes a global binding.
    editor.keymap('global', bindings)
  end
  function editor.set_context_keymap(context, name)
    context = scope(context)
    assert(maps[name] and name~='global', 'Unknown or global context keymap: '..tostring(name))
    for _, entry in ipairs(stacks[context]) do assert(entry.name~=name, 'Keymap already transient: '..name) end
    contexts[context], pending = name, nil
  end
  function editor.push_keymap(name, config)
    config = options(config, {context=true, priority=true})
    local context = scope(config.context)
    assert(maps[name] and name~='global' and name~=contexts[context],
      'Unknown or contextual transient keymap: '..tostring(name))
    local rank = config.priority~=nil and priority(config.priority) or nil
    for _, entry in ipairs(stacks[context]) do assert(entry.name~=name, 'Keymap already active: '..name) end
    table.insert(stacks[context], {name=name, priority=rank})
    pending = nil
    return name
  end
  local function layers(context)
    local result={}
    for order, entry in ipairs(stacks[context]) do
      result[#result+1]={name=entry.name, kind='transient', order=order,
        priority=entry.priority or maps[entry.name].priority}
    end
    table.sort(result, function(a,b)
      return a.priority>b.priority or (a.priority==b.priority and a.order>b.order)
    end)
    result[#result+1]={name=contexts[context], kind='context', priority=maps[contexts[context]].priority}
    result[#result+1]={name='global', kind='global', priority=maps.global.priority}
    return result
  end
  function editor.pop_keymap(config)
    config = options(config, {context=true})
    local context = scope(config.context)
    local top = layers(context)[1]
    if top.kind~='transient' then return nil end
    table.remove(stacks[context], top.order)
    pending = nil
    return top.name
  end
  function editor._keymap_focus(context, reset)
    context = scope(context)
    if focused~=context or reset then focused, pending = context, nil end
  end
  function editor.cancel_key_sequence()
    local had_pending = pending~=nil
    pending = nil
    return had_pending
  end
  function editor.keymap_names(prefix)
    local names={}
    prefix=prefix or ''
    for name in pairs(maps) do if name:sub(1,#prefix)==prefix then names[#names+1]=name end end
    table.sort(names)
    return names
  end
  local function continuations(node)
    local result={}
    for key, child in pairs(node.children) do
      result[#result+1]={key=key, command=child.command, prefix=child.command==nil}
    end
    table.sort(result, function(a,b) return a.key<b.key end)
    return result
  end
  function editor.keymap_state(context)
    context = scope(context)
    local active, bindings, owners = layers(context), {}, {}
    for _, layer in ipairs(active) do
      for sequence, command in pairs(maps[layer.name].bindings) do
        local first = tokens(sequence)[1]
        bindings[#bindings+1]={map=layer.name, kind=layer.kind, sequence=sequence, command=command,
          available=type(editor.commands[command])=='function', shadowed_by=owners[first]}
      end
      for key in pairs(maps[layer.name].root.children) do owners[key]=owners[key] or layer.name end
    end
    table.sort(bindings, function(a,b)
      return a.map<b.map or (a.map==b.map and a.sequence<b.sequence)
    end)
    local waiting
    if pending and pending.context==context then
      waiting={map=pending.map, sequence=pending.sequence, continuations=continuations(pending.node)}
    end
    return {context=context, focused=focused, layers=active, bindings=bindings, pending=waiting}
  end
  function editor.keymap_info(name, context)
    assert(maps[name], 'Unknown keymap: '..tostring(name))
    local state, bindings, active = editor.keymap_state(context), {}, false
    for _, layer in ipairs(state.layers) do if layer.name==name then active=true end end
    for sequence, command in pairs(maps[name].bindings) do
      local shadowed
      for _, binding in ipairs(state.bindings) do
        if binding.map==name and binding.sequence==sequence then shadowed=binding.shadowed_by; break end
      end
      bindings[#bindings+1]={sequence=sequence, command=command, shadowed_by=shadowed,
        available=type(editor.commands[command])=='function'}
    end
    table.sort(bindings, function(a,b) return a.sequence<b.sequence end)
    return {name=name, priority=maps[name].priority, active=active, bindings=bindings}
  end
  function editor.command_bindings(command)
    local bindings={}
    for name, map in pairs(maps) do
      for sequence, target in pairs(map.bindings) do
        if target==command then bindings[#bindings+1]=name=='global' and sequence or name..': '..sequence end
      end
    end
    table.sort(bindings)
    return bindings
  end
  function editor.validate_keymaps()
    -- Forward command references are allowed while loading; activation validates every map.
    for name, map in pairs(maps) do
      for sequence, command in pairs(map.bindings) do
        assert(type(editor.commands[command])=='function', name..': '..sequence..': unknown command '..command)
      end
    end
  end
  local function feedback(message)
    return {kind='key-feedback', message=message}
  end
  local function wait(context, name, sequence, node)
    pending={context=context, map=name, sequence=sequence, node=node}
    local hints={}
    for _, item in ipairs(continuations(node)) do
      hints[#hints+1]=item.key..' -> '..(item.command or 'prefix')
    end
    return feedback(sequence..' ... ['..name..'] '..table.concat(hints,' | '))
  end
  function editor.dispatch(key, snapshot, text)
    local context = snapshot.surface
    editor._keymap_focus(context)
    local is_text = key=='text'
    if is_text then key=text==' ' and 'space' or text end
    if pending then
      local previous=pending
      pending=nil
      if key=='escape' or key=='ctrl-g' then return feedback('Prefix cancelled') end
      local node=previous.node.children[key]
      local sequence=previous.sequence..' '..key
      if not node then return feedback('Unbound sequence: '..sequence) end
      if node.command then return editor.execute(node.command, snapshot, text) end
      return wait(context, previous.map, sequence, node)
    end
    for _, layer in ipairs(layers(context)) do
      local node=maps[layer.name].root.children[key]
      if node then
        if node.command then return editor.execute(node.command, snapshot, text) end
        return wait(context, layer.name, key, node)
      end
    end
    if is_text and text~='' then return editor.execute('insert', snapshot, text) end
  end
  editor.keymap('global', {})
  editor.keymap('document', {})
  editor.keymap('minibuffer', {})
end

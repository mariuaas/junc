-- Independently defined extension; it receives exactly the ordinary command API.
return function(editor)
  editor.command('wrap', function(c)
    return editor.replace(c, '(' .. c.selection .. ')')
  end)
end

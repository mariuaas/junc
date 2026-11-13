-- Independently defined extension; it receives exactly the ordinary command API.
return function(editor)
  editor.command('wrap', function(c)
    return editor.each(c, function(one)
      return editor.replace(one, '(' .. one.selection .. ')')
    end)
  end)
end

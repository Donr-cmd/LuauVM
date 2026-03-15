print(type(io))
print(type(readfile))
print(type(require))
for k,v in pairs(_G) do print(k, type(v)) end

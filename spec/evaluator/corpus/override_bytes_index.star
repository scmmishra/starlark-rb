# Spec, "Bytes": indexing a bytes value returns the byte as an int.
# starlark-go returns a one-byte bytes value.
b = b"abc"
print(b[0], b[-1], type(b[1]))

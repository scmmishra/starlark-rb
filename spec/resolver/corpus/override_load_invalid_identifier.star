# Spec, "Load statements": a loaded name must denote a valid identifier.
# starlark-go and Java Starlark accept any string. We reject the name, and
# skip binding it.
load("m.star", "x-y", "if", "1x", ok = "while", "fine")

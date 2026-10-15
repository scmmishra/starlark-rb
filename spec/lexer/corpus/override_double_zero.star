# Spec, "Literals": an int starting with 0 is 0 itself, or has an 0x or 0o
# prefix. starlark-go accepts 00 as 0. Java Starlark rejects it.
x = 00

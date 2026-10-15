# Spec, "Literals": an octal literal may have any number of digits, and ints
# have arbitrary precision. starlark-go rejects octal literals above 64 bits.
# Java Starlark accepts them.
x = 0o7777777777777777777777

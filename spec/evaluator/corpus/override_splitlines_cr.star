# Spec, "string·splitlines": lines end at "\n", "\r", or "\r\n".
# starlark-go splits at "\n" only.
print("A\nB\rC\r\nD".splitlines(), "a\r\nb\r".splitlines(True), "\r".splitlines())

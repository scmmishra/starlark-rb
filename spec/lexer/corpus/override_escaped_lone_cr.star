# A backslash before a lone CR inside a string is an escaped newline, as in
# Java Starlark. starlark-go gives the same values, but it counts each lone CR
# as a new line, so its positions differ. See override_lone_cr.
x = 'a\b'
y = '''c\d'''
z = b'e\f'

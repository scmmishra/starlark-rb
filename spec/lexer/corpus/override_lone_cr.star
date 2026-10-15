# Spec, "Lexical elements": a carriage return is white space, and only LF
# and CRLF end a line. starlark-go treats a lone CR as a newline. Java
# Starlark treats it as white space outside strings and as a literal
# character inside them.
x = 1y = 2 # commentz
a = 'pq' + '''rs'''
if a:
      b
r = r'g\h'

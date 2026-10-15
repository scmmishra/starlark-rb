# Spec, "Bytes literals": a raw bytes literal may use either a br or an rb
# prefix. starlark-go only recognizes rb, and lexes br as an identifier.
x = br'a\nb' + rb"a\nb" + BR"c"

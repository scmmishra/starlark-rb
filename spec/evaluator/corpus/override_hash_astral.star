# Spec, "hash": strings hash like Java String.hashCode over UTF-16, so a
# character above U+FFFF counts as two surrogate units. starlark-go hashes it as
# one unit.
print(hash("😀"), hash("a😀b"))

print('a,b,,c'.split(','), 'a,b,,c'.split(',', 1), 'a,b,,c'.rsplit(',', 1), '  one two  three '.split(), ' one two three '.split(None, 1), ' one two three '.rsplit(None, 1), 'x'.split('x'), ''.split(','), ''.split())
print('  1  2  3  '.split(' '), 'abc'.split('abc'), 'aaa'.split('a', 2), 'aaa'.rsplit('a', 2))

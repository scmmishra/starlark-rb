b = b'abc\xff'
print(b, len(b), b[1:3], b + b'!', b * 2, b'bc' in b, 98 in b, str(b), repr(b), bytes('héllo'), bytes([65, 66]), list(b.elems()), b.elems(), type(b.elems()), hash(b'abc'))

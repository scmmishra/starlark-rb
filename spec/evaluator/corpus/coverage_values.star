def main():
    d = {1: 2}
    d.clear()
    print(d, 5 in range(10, 0, -1), 0 in range(10, 0, -1), 11 in range(10, 0, -1))
    print(type(b""), bool(0.0), bool(0.5), bool(len), b"a" < b"b", b"b" <= b"a")
    print(+3, +2.5, ~7, 6 | 3, 6 & 3, 6 ^ 3, {1: 2} | {3: 4}, b"abcdef"[::2], b"" * 3, () * 3, [] * 2, b"ab" * 0)
    print(repr("\U000E0001"), str("plain"), str(b"\xffok"))
    x = 1
    def g():
        return x
    print(x + g())
    e = {1: 1}
    e |= {2: 2}
    print(e, set([1]) | set([2]))
main()

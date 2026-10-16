def main():
    print(int("00", 0), int("0", 0), int("-0x10", 0), float(True), float(False), float(1.5), bytes(b"x"), abs(-0.0))
    print(sorted([3, 1], reverse=False), max([1, 2], key=None), list(enumerate("ab".elems(), start=1)) if False else 1)
main()

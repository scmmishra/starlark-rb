def main():
    x = [3, 1, 2]
    x.append(4)
    x.extend((5, 6))
    x.insert(0, 0)
    x.insert(-1, 9)
    x.insert(100, 10)
    print(x, x.pop(), x.pop(0), x.index(2), x.index(2, 1), x)
    x.remove(9)
    print(x, x[1:4], x[::-2], x * 2, [1] + [2], 2 in x, len(x))
    x.clear()
    print(x)
    y = [1, 2]
    y += (3,)
    y += 'ab'.elems()
    print(y)
main()

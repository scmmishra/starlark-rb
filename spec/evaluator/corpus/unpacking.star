a, b = 1, 2
[c, (d, e)] = [3, (4, 5)]
print(a, b, c, d, e)
def f():
    (x,) = [9]
    for k, v in {'a': 1}.items():
        print(k, v, x)
f()

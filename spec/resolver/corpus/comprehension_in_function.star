def f(n):
    a = [i * n for i in range(n)]
    b = [i for i in a if i]
    return a, b

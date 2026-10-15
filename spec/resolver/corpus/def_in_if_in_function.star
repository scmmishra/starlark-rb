def f(x):
    if x:
        def g():
            return x
        return g

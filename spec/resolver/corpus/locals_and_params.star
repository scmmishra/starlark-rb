def f(a, b=1, *args, c, d=2, **kwargs):
    e = a + b + c + d
    return e, args, kwargs

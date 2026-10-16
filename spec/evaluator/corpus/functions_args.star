def f(a, b=2, *args, c, d=4, **kwargs):
    return a, b, args, c, d, kwargs
print(f(1, c=3))
print(f(1, 2, 3, 4, c=5, e=6))
print(f(*[1, 2], **{'c': 3, 'z': 0}))
def g(*, x, y=1):
    return x + y
print(g(x=1), g(y=2, x=3))
h = lambda *a, **k: (a, k)
print(h(1, k=2))

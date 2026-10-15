def a(): pass
def b(x): pass
def c(x, y=1, z=f(2)): pass
def d(*args): pass
def e(**kwargs): pass
def f(x, *args, y, z=3, **kwargs): pass
def g(x, *, y): pass
def h(x,): pass
def i(*, x=1,): pass
def j(
    x,
    y = 2,
):
    return x

def counter():
    count = [0]
    def inc():
        count[0] += 1
        return count[0]
    return inc
c = counter()
print(c(), c(), c())
def adders():
    return [lambda x, i=i: x + i for i in range(3)]
print([f(10) for f in adders()])
def late():
    fs = [lambda: i for i in range(3)]
    return [f() for f in fs]
print(late())
def outer(x):
    def mid():
        def inner():
            return x
        return inner
    return mid()()
print(outer('deep'))

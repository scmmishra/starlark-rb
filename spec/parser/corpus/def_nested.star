def outer(x):
    def inner(y):
        return x + y
    return inner

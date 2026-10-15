def outer(a):
    b = 1
    def mid():
        def inner():
            return a + b
        return inner
    return mid

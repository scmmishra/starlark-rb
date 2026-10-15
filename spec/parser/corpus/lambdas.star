f = lambda: 0
f = lambda x: x
f = lambda x, y=1, *args, **kwargs: x
f = lambda *, x: x
f = lambda x: lambda y: x + y
g(lambda x: x, key = lambda y: -y)
h = [lambda: 1, lambda: 2]
k = [x for x in y if lambda: z]

def f():
    for x in y:
        pass
    for x, y in z:
        pass
    for (x, y) in z:
        pass
    for x.a, y[0] in z:
        pass
    for x in 1, 2, 3:
        pass
    for x in a if b else c:
        break
    for x in y: continue

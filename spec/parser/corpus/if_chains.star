def f(x):
    if x:
        a()
    if x:
        a()
    else:
        b()
    if x:
        a()
    elif y:
        b()
    elif z:
        c()
    else:
        d()
    if x: a(); b()
    if x: pass
    elif y: pass
    else: pass

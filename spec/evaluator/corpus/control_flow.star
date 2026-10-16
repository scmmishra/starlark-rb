def f(n):
    out = []
    for i in range(n):
        if i == 1:
            continue
        elif i == 4:
            break
        else:
            out.append(i)
    return out
print(f(10))
def g(x):
    return 'a' if x else 'b'
print(g(1), g(0), 1 and 2, 0 and 2, 0 or 3, None or [], not 0, not [1])

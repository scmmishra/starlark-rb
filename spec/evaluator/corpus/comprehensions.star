print([x * x for x in range(5) if x % 2], [(x, y) for x in range(3) for y in range(x)], {x: x * 2 for x in range(3)}, [[y for y in range(x)] for x in range(3)])
x = 'outer'
print([x for x in 'ab'.elems()], x)

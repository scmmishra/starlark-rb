nan = float('nan')
print(nan == nan, nan < 1.0, 1.0 < nan, nan > float('inf'))
print(sorted([3.0, nan, 1.0, float('-inf')]))
print(1 == 1.0, (1 << 53) + 1 == float((1 << 53) + 1), 2 < 2.5)
d = {1: 'a'}
d[1.0] = 'b'
print(d)

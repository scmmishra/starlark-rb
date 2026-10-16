# Spec, "range": x in range reports whether x equals a member. starlark-go
# truncates a float first, so it reports 1.5 in range(5).
print(2.0 in range(5), 1.5 in range(5), -0.0 in range(1), 2 in range(0, 5, 2))

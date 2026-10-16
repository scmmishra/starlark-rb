# Spec, "Sets": difference, intersection, union, and update take any number
# of collections, and sets have difference_update, intersection_update,
# symmetric_difference_update, and isdisjoint. starlark-go has neither.
s = set([1, 2, 3, 4])
s.difference_update([2], [3])
print(s)
s.intersection_update([1, 4, 5])
print(s)
s.symmetric_difference_update([4, 6])
print(s, s.isdisjoint([7]), s.isdisjoint([1]), set([1, 2, 3]).difference([1], [2]), set([1, 2, 3]).intersection([1, 2], [2]), set([1, 2]).union([3], [4]))

def main():
    d = {'b': 1, 'a': 2}
    d['c'] = 3
    d['b'] = 4
    print(d, d.keys(), d.values(), d.items(), d.get('a'), d.get('z'), d.get('z', 0), 'a' in d, len(d))
    print(d.pop('a'), d.pop('z', 'dflt'), d.setdefault('e', 5), d.setdefault('b', 9), d.popitem(), d)
    d.update([('x', 1)], y=2)
    d.update({'z': 3})
    print(d, dict(a=1), dict([(1, 2)], b=3), dict({'k': 'v'}), {'a': 1} | {'a': 2, 'b': 3})
    e = {1: 1}
    e |= {2: 2}
    print(e, {k: v for k, v in [(1, 2), (3, 4)]}, sorted({'b': 1, 'a': 2}))
main()

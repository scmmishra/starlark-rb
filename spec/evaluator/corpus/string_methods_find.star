s = 'bonbon'
print(s.find('on'), s.find('on', 2), s.find('on', 2, 5), s.rfind('on'), s.rfind('on', None, 5), s.index('on'), s.rindex('on'), s.count('o'), s.count('o', 2), s.count(''), s.find(''), s.find('', 10))
print(s.startswith('bon'), s.startswith(('x', 'bo')), s.endswith('on', 0, 3), s.startswith('n', 2))

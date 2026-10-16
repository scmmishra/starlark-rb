def main():
    print("hello world".capitalize(), "HELLO".capitalize(), "".capitalize(), "Hello World".istitle(), "hello World".istitle(), "HeLLo".istitle(), "Ab Cd".istitle())
    print("a b".split(" ", 0), "a b c".rsplit(" ", 1), " a  b ".split(None, 0), " a  b ".rsplit(None, 0))
    x = [1, 2]
    x.clear()
    s = set([1])
    s.clear()
    set().clear()
    print(x, s, "%d %s" % (1, "a"), "%s" % "solo", "100%%" % (), "%(k)s" % {"k": "v"})
main()

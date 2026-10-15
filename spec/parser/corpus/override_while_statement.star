# The spec grammar has no while statement. starlark-go parses one.
# Java Starlark rejects it, and we use its message.
def f():
    while x:
        pass

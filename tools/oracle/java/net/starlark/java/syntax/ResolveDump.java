// Prints Java Starlark's name resolution for one file in the oracle format
// described in tools/oracle/README.md.
package net.starlark.java.syntax;

import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Set;

public final class ResolveDump {
  // The spec's builtins. Keep in sync with tools/oracle/README.md.
  private static final Set<String> UNIVERSAL = Set.of(
      "None", "True", "False", "abs", "any", "all", "bool", "bytes", "dict", "dir", "enumerate", "fail",
      "float", "getattr", "hasattr", "hash", "int", "len", "list", "max", "min", "print", "range", "repr",
      "reversed", "set", "sorted", "str", "tuple", "type", "zip");

  // Names the host adds. The conformance tests use these.
  private static final Set<String> PREDECLARED = Set.of("assert_eq", "assert_ne", "assert_");

  // Every option matches the spec.
  private static final FileOptions OPTIONS = FileOptions.builder()
      .allowLoadPrivateSymbols(false)
      .allowToplevelRebinding(false)
      .loadBindsGlobally(false)
      .requireLoadStatementsFirst(false)
      .stringLiteralsAreAsciiOnly(false)
      .build();

  private record Entry(Location location, List<String> lines) {}

  public static void main(String[] args) throws Exception {
    if (args.length != 1) {
      System.err.println("usage: ResolveDump FILE");
      System.exit(2);
    }
    byte[] bytes = Files.readAllBytes(Path.of(args[0]));
    PrintStream out = new PrintStream(System.out, false, StandardCharsets.UTF_8);
    // A fixed file name, as in the Go dumper, because some messages include it.
    StarlarkFile file = StarlarkFile.parse(ParserInput.fromUTF8(bytes, "input.star"), OPTIONS);
    if (file.ok()) {
      Resolver.resolveFile(file, ResolveDump::scopeOf);
    }
    if (!file.ok()) {
      for (SyntaxError e : file.errors()) {
        out.printf("%d:%d ERROR %s%n", e.location().line(), e.location().column(), e.message());
      }
      out.flush();
      return;
    }

    Resolver.Function toplevel = file.getResolvedFunction();
    out.printf("module%n  locals: %s%n  globals: %s%n",
        names(toplevel.getLocals(), toplevel.getCellIndices()), String.join(" ", toplevel.getGlobals()));

    // Identifiers that declare a name without being an expression. The
    // function headers cover the declarations.
    Set<Identifier> skip = Collections.newSetFromMap(new IdentityHashMap<>());
    List<Entry> entries = new ArrayList<>();
    new NodeVisitor() {
      @Override
      public void visit(DefStatement node) {
        skip.add(node.getIdentifier());
        skipParams(skip, node.getParameters());
        entries.add(function(node.getStartLocation(), node.getResolvedFunction()));
        super.visit(node);
      }

      @Override
      public void visit(LambdaExpression node) {
        skipParams(skip, node.getParameters());
        entries.add(function(node.getStartLocation(), node.getResolvedFunction()));
        super.visit(node);
      }

      @Override
      public void visit(LoadStatement node) {
        for (LoadStatement.Binding b : node.getBindings()) {
          skip.add(b.getLocalName());
          skip.add(b.getOriginalName());
        }
        super.visit(node);
      }

      @Override
      public void visit(DotExpression node) {
        skip.add(node.getField());
        super.visit(node);
      }

      @Override
      public void visit(Argument node) {
        if (node instanceof Argument.Keyword k) {
          skip.add(k.getIdentifier());
        }
        super.visit(node);
      }

      @Override
      public void visit(Identifier node) {
        // A bare "*" parameter has no identifier, and the visitor passes null.
        if (node != null && !skip.contains(node)) {
          entries.add(new Entry(node.getStartLocation(), List.of(ident(node))));
        }
      }
    }.visit(file);

    entries.sort(Comparator.comparingInt((Entry e) -> e.location().line())
        .thenComparingInt(e -> e.location().column()));
    for (Entry e : entries) {
      out.printf("%d:%d %s%n", e.location().line(), e.location().column(), e.lines().get(0));
      for (String line : e.lines().subList(1, e.lines().size())) {
        out.printf("  %s%n", line);
      }
    }
    out.flush();
  }

  private static Resolver.Scope scopeOf(String name) throws Resolver.Module.Undefined {
    if (PREDECLARED.contains(name)) {
      return Resolver.Scope.PREDECLARED;
    }
    if (UNIVERSAL.contains(name)) {
      return Resolver.Scope.UNIVERSAL;
    }
    throw new Resolver.Module.Undefined(name + " is not defined", Set.of());
  }

  private static void skipParams(Set<Identifier> skip, List<Parameter> params) {
    for (Parameter p : params) {
      if (p.getIdentifier() != null) {
        skip.add(p.getIdentifier());
      }
    }
  }

  private static Entry function(Location location, Resolver.Function fn) {
    StringBuilder header = new StringBuilder("function " + fn.getName());
    if (fn.hasVarargs()) {
      header.append(" varargs");
    }
    if (fn.hasKwargs()) {
      header.append(" kwargs");
    }
    if (fn.numKeywordOnlyParams() > 0) {
      header.append(" kwonly=").append(fn.numKeywordOnlyParams());
    }
    List<String> free = new ArrayList<>();
    for (Resolver.Binding b : fn.getFreeVars()) {
      free.add(b.getName() + (b.getScope() == Resolver.Scope.CELL ? "*" : ""));
    }
    return new Entry(location, List.of(
        header.toString(),
        "locals: " + names(fn.getLocals(), fn.getCellIndices()),
        "free: " + String.join(" ", free)));
  }

  // Lists names in slot order. A trailing * marks a cell.
  private static String names(List<Resolver.Binding> bindings, int[] cells) {
    List<String> out = new ArrayList<>();
    for (int i = 0; i < bindings.size(); i++) {
      boolean cell = false;
      for (int c : cells) {
        cell |= c == i;
      }
      out.add(bindings.get(i).getName() + (cell ? "*" : ""));
    }
    return String.join(" ", out);
  }

  private static String ident(Identifier id) {
    Resolver.Binding b = id.getBinding();
    if (b == null) {
      return "Ident " + id.getName() + " unresolved";
    }
    String scope = b.getScope().toString().toLowerCase();
    if (b.getScope() == Resolver.Scope.PREDECLARED || b.getScope() == Resolver.Scope.UNIVERSAL) {
      return "Ident " + id.getName() + " " + scope;
    }
    return "Ident " + id.getName() + " " + scope + " " + b.getIndex();
  }
}

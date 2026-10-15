// Prints Java Starlark's syntax tree for one file in the oracle format
// described in tools/oracle/README.md.
package net.starlark.java.syntax;

import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

public final class ParseDump {
  private final PrintStream out;

  private ParseDump(PrintStream out) {
    this.out = out;
  }

  public static void main(String[] args) throws Exception {
    if (args.length != 1) {
      System.err.println("usage: ParseDump FILE");
      System.exit(2);
    }
    byte[] bytes = Files.readAllBytes(Path.of(args[0]));
    StarlarkFile file = StarlarkFile.parse(ParserInput.fromUTF8(bytes, args[0]), FileOptions.DEFAULT);
    PrintStream out = new PrintStream(System.out, false, StandardCharsets.UTF_8);
    if (!file.ok()) {
      SyntaxError e = file.errors().get(0);
      out.printf("%d:%d ERROR %s%n", e.location().line(), e.location().column(), e.message());
    } else {
      ParseDump d = new ParseDump(out);
      for (Statement s : file.getStatements()) {
        d.node(s, 0);
      }
    }
    out.flush();
  }

  private void line(Node n, int depth, String text) {
    Location loc = n.getStartLocation();
    out.printf("%s%d:%d %s%n", "  ".repeat(depth), loc.line(), loc.column(), text);
  }

  private void label(int depth, String text) {
    out.printf("%s%s%n", "  ".repeat(depth), text);
  }

  private void stmts(String label, List<Statement> stmts, int depth) {
    label(depth, label);
    for (Statement s : stmts) {
      node(s, depth + 1);
    }
  }

  private void node(Node n, int depth) {
    if (n instanceof DefStatement s) {
      line(s, depth, "DefStmt " + s.getIdentifier().getName());
      for (Parameter p : s.getParameters()) {
        param(p, depth + 1);
      }
      stmts("body", s.getBody(), depth + 1);
    } else if (n instanceof IfStatement s) {
      line(s, depth, "IfStmt");
      node(s.getCondition(), depth + 1);
      stmts("then", s.getThenBlock(), depth + 1);
      if (s.getElseBlock() != null && !s.getElseBlock().isEmpty()) {
        stmts("else", s.getElseBlock(), depth + 1);
      }
    } else if (n instanceof ForStatement s) {
      line(s, depth, "ForStmt");
      node(s.getVars(), depth + 1);
      node(s.getCollection(), depth + 1);
      stmts("body", s.getBody(), depth + 1);
    } else if (n instanceof ReturnStatement s) {
      line(s, depth, "ReturnStmt");
      if (s.getResult() != null) {
        node(s.getResult(), depth + 1);
      }
    } else if (n instanceof FlowStatement s) {
      line(s, depth, "BranchStmt " + s.getFlowKind().toString());
    } else if (n instanceof AssignmentStatement s) {
      String op = s.isAugmented() ? s.getOperator().toString() + "=" : "=";
      line(s, depth, "AssignStmt " + op);
      node(s.getLHS(), depth + 1);
      node(s.getRHS(), depth + 1);
    } else if (n instanceof ExpressionStatement s) {
      line(s, depth, "ExprStmt");
      node(s.getExpression(), depth + 1);
    } else if (n instanceof LoadStatement s) {
      line(s, depth, "LoadStmt " + quote(s.getImport().getValue()));
      for (LoadStatement.Binding b : s.getBindings()) {
        line(b.getLocalName(), depth + 1,
            "LoadBinding " + b.getLocalName().getName() + " " + b.getOriginalName().getName());
      }
    } else if (n instanceof Identifier x) {
      line(x, depth, "Ident " + x.getName());
    } else if (n instanceof IntLiteral x) {
      line(x, depth, "Literal int " + x.getValue());
    } else if (n instanceof FloatLiteral x) {
      line(x, depth, String.format("Literal float %016x", Double.doubleToRawLongBits(x.getValue())));
    } else if (n instanceof StringLiteral x) {
      line(x, depth, "Literal string " + quote(x.getValue()));
    } else if (n instanceof ListExpression x) {
      line(x, depth, x.isTuple() ? "TupleExpr" : "ListExpr");
      for (Expression e : x.getElements()) {
        node(e, depth + 1);
      }
    } else if (n instanceof DictExpression x) {
      line(x, depth, "DictExpr");
      for (DictExpression.Entry e : x.getEntries()) {
        node(e, depth + 1);
      }
    } else if (n instanceof DictExpression.Entry x) {
      line(x, depth, "DictEntry");
      node(x.getKey(), depth + 1);
      node(x.getValue(), depth + 1);
    } else if (n instanceof Comprehension x) {
      line(x, depth, "Comprehension " + (x.isDict() ? "dict" : "list"));
      node(x.getBody(), depth + 1);
      for (Comprehension.Clause c : x.getClauses()) {
        node(c, depth + 1);
      }
    } else if (n instanceof Comprehension.For x) {
      line(x, depth, "ForClause");
      node(x.getVars(), depth + 1);
      node(x.getIterable(), depth + 1);
    } else if (n instanceof Comprehension.If x) {
      line(x, depth, "IfClause");
      node(x.getCondition(), depth + 1);
    } else if (n instanceof ConditionalExpression x) {
      line(x, depth, "IfExpr");
      node(x.getCondition(), depth + 1);
      node(x.getThenCase(), depth + 1);
      node(x.getElseCase(), depth + 1);
    } else if (n instanceof UnaryOperatorExpression x) {
      line(x, depth, "UnaryExpr " + x.getOperator().toString());
      node(x.getX(), depth + 1);
    } else if (n instanceof BinaryOperatorExpression x) {
      line(x, depth, "BinaryExpr " + x.getOperator().toString());
      node(x.getX(), depth + 1);
      node(x.getY(), depth + 1);
    } else if (n instanceof LambdaExpression x) {
      line(x, depth, "LambdaExpr");
      for (Parameter p : x.getParameters()) {
        param(p, depth + 1);
      }
      label(depth + 1, "body");
      node(x.getBody(), depth + 2);
    } else if (n instanceof DotExpression x) {
      line(x, depth, "DotExpr " + x.getField().getName());
      node(x.getObject(), depth + 1);
    } else if (n instanceof CallExpression x) {
      line(x, depth, "CallExpr");
      node(x.getFunction(), depth + 1);
      for (Argument a : x.getArguments()) {
        arg(a, depth + 1);
      }
    } else if (n instanceof IndexExpression x) {
      line(x, depth, "IndexExpr");
      node(x.getObject(), depth + 1);
      node(x.getKey(), depth + 1);
    } else if (n instanceof SliceExpression x) {
      line(x, depth, "SliceExpr");
      node(x.getObject(), depth + 1);
      slicePart("start", x.getStart(), depth + 1);
      slicePart("stop", x.getStop(), depth + 1);
      slicePart("step", x.getStep(), depth + 1);
    } else {
      label(depth, "UNKNOWN " + n.getClass().getSimpleName());
    }
  }

  private void slicePart(String label, Expression x, int depth) {
    if (x != null) {
      label(depth, label);
      node(x, depth + 1);
    }
  }

  private void param(Parameter p, int depth) {
    if (p instanceof Parameter.Mandatory) {
      line(p, depth, "Param required " + p.getName());
    } else if (p instanceof Parameter.Optional) {
      line(p, depth, "Param optional " + p.getName());
      node(p.getDefaultValue(), depth + 1);
    } else if (p instanceof Parameter.StarStar) {
      line(p, depth, "Param kwargs " + p.getName());
    } else if (p instanceof Parameter.Star) {
      line(p, depth, p.getName() == null ? "Param star" : "Param args " + p.getName());
    } else {
      label(depth, "UNKNOWN param " + p.getClass().getSimpleName());
    }
  }

  private void arg(Argument a, int depth) {
    if (a instanceof Argument.Keyword) {
      line(a, depth, "Arg keyword " + a.getName());
    } else if (a instanceof Argument.Star) {
      line(a, depth, "Arg args");
    } else if (a instanceof Argument.StarStar) {
      line(a, depth, "Arg kwargs");
    } else {
      line(a, depth, "Arg positional");
    }
    node(a.getValue(), depth + 1);
  }

  // Prints printable ASCII as is and every other byte as \xHH, like the lexer oracle.
  private static String quote(String s) {
    StringBuilder sb = new StringBuilder("\"");
    for (byte b : s.getBytes(StandardCharsets.UTF_8)) {
      int c = b & 0xff;
      if (c >= 0x20 && c < 0x7f && c != '"' && c != '\\') {
        sb.append((char) c);
      } else {
        sb.append(String.format("\\x%02x", c));
      }
    }
    return sb.append('"').toString();
  }
}

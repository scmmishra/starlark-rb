// Prints the Java Starlark lexer's tokens for one file.
// It lives in net.starlark.java.syntax because Lexer is package-private.
package net.starlark.java.syntax;

import java.io.PrintStream;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

public final class LexDump {
  // Java token names that differ from starlark-go's. All other names match.
  private static final Map<String, String> RENAMES = Map.ofEntries(
      Map.entry("AMPERSAND", "AMP"),
      Map.entry("AMPERSAND_EQUALS", "AMP_EQ"),
      Map.entry("CARET", "CIRCUMFLEX"),
      Map.entry("CARET_EQUALS", "CIRCUMFLEX_EQ"),
      Map.entry("EQUALS", "EQ"),
      Map.entry("EQUALS_EQUALS", "EQL"),
      Map.entry("GREATER", "GT"),
      Map.entry("GREATER_EQUALS", "GE"),
      Map.entry("GREATER_GREATER", "GTGT"),
      Map.entry("GREATER_GREATER_EQUALS", "GTGT_EQ"),
      Map.entry("IDENTIFIER", "IDENT"),
      Map.entry("LBRACKET", "LBRACK"),
      Map.entry("RBRACKET", "RBRACK"),
      Map.entry("LESS", "LT"),
      Map.entry("LESS_EQUALS", "LE"),
      Map.entry("LESS_LESS", "LTLT"),
      Map.entry("LESS_LESS_EQUALS", "LTLT_EQ"),
      Map.entry("MINUS_EQUALS", "MINUS_EQ"),
      Map.entry("NOT_EQUALS", "NEQ"),
      Map.entry("PERCENT_EQUALS", "PERCENT_EQ"),
      Map.entry("PIPE_EQUALS", "PIPE_EQ"),
      Map.entry("PLUS_EQUALS", "PLUS_EQ"),
      Map.entry("SLASH_EQUALS", "SLASH_EQ"),
      Map.entry("SLASH_SLASH", "SLASHSLASH"),
      Map.entry("SLASH_SLASH_EQUALS", "SLASHSLASH_EQ"),
      Map.entry("STAR_EQUALS", "STAR_EQ"),
      Map.entry("STAR_STAR", "STARSTAR"));

  public static void main(String[] args) throws Exception {
    if (args.length != 1) {
      System.err.println("usage: LexDump FILE");
      System.exit(2);
    }
    byte[] bytes = Files.readAllBytes(Path.of(args[0]));
    ParserInput input = ParserInput.fromUTF8(bytes, args[0]);
    char[] content = input.getContent();
    List<SyntaxError> errors = new ArrayList<>();
    Lexer lexer = new Lexer(input, errors, FileOptions.DEFAULT);
    PrintStream out = new PrintStream(System.out, false, StandardCharsets.UTF_8);

    while (true) {
      lexer.nextToken();
      if (!errors.isEmpty()) {
        SyntaxError e = errors.get(0);
        Location loc = e.location();
        out.printf("%d:%d\tERROR\t%s%n", loc.line(), codePointColumn(content, loc), e.message());
        break;
      }
      Location loc = lexer.locs.getLocation(lexer.start);
      String name = lexer.kind.name();
      out.printf("%d:%d\t%s\t%s%n",
          loc.line(), codePointColumn(content, loc), RENAMES.getOrDefault(name, name), value(lexer));
      if (lexer.kind == TokenKind.EOF) {
        break;
      }
    }
    out.flush();
  }

  private static String value(Lexer lexer) {
    switch (lexer.kind) {
      case IDENTIFIER:
        return (String) lexer.value;
      case INT:
        return lexer.value.toString();
      case FLOAT:
        return String.format("%016x", Double.doubleToRawLongBits((Double) lexer.value));
      case STRING:
        return quote(((String) lexer.value).getBytes(StandardCharsets.UTF_8));
      default:
        return "";
    }
  }

  // Prints printable ASCII as is and every other byte as \xHH, like the Go oracle.
  private static String quote(byte[] bytes) {
    StringBuilder sb = new StringBuilder("\"");
    for (byte b : bytes) {
      int c = b & 0xff;
      if (c >= 0x20 && c < 0x7f && c != '"' && c != '\\') {
        sb.append((char) c);
      } else {
        sb.append(String.format("\\x%02x", c));
      }
    }
    return sb.append('"').toString();
  }

  // Java columns count UTF-16 chars. starlark-go columns count code points.
  private static int codePointColumn(char[] content, Location loc) {
    int lineStart = 0;
    for (int line = 1; line < loc.line() && lineStart < content.length; lineStart++) {
      if (content[lineStart] == '\n') {
        line++;
      }
    }
    int end = Math.min(lineStart + loc.column() - 1, content.length);
    if (end < lineStart) {
      return loc.column();
    }
    return Character.codePointCount(content, lineStart, end - lineStart) + 1;
  }
}

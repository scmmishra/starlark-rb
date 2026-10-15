# Starlark Interpreter in Ruby

A Starlark language interpreter implementation in Ruby.

## Development

### Requirements

- Ruby (managed via mise)

### Setup

1. Install mise (if not already installed):
   ```bash
   curl https://mise.jq.sh | sh
   ```

2. Install Ruby version specified in `.mise.toml`:
   ```bash
   mise install
   ```

3. Install dependencies:
   ```bash
   bundle install
   ```

## Project Structure

- `lib/starlark/` - Core interpreter implementation
- `bin/` - Command-line executable
- `spec/` - Test suite

## License

MIT

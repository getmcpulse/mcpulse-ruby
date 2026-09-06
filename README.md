# mcpulse

Analytics for MCP servers, in Ruby.

```ruby
require "mcpulse"

MCPulse.configure(key: "mp_live_…")

# Around your tool handler:
MCPulse.record("search", arguments, client_name: client) do
  my_handler.call(arguments)
end
```

Wrapping the handler rather than watching from outside is what lets MCPulse tell
a handler that raised from one that returned an error result — a distinction an
MCP server erases by converting both into `isError` before anything outside sees
it.

## Install

```ruby
gem "mcpulse"
```

No runtime dependencies. This gem loads into other people's servers, and a
dependency that conflicts with what the customer already bundles is a support
burden with no upside for a single POST.

## Options

| Keyword | Default | Meaning |
|---|---|---|
| `key:` | — | Ingest key, `mp_live_…`, minted per MCP in the dashboard |
| `endpoint:` | `https://api.getmcpulse.com` | Point at a local API while developing |
| `enabled:` | `true` | `false` makes everything a no-op — useful in tests and CI |
| `debug:` | `false` | Log what is sent, and why a send failed, to **stderr** |

An empty key turns it off, so a server started without its key configured is
silent rather than a source of 401s on every flush.

## Reporting your tools

```ruby
MCPulse.record_startup(tools_list_response, client_name: client)
```

Pass the JSON your `tools/list` returns — `schema_bytes` is the cost of a tool's
presence in the context window, so it has to be measured on what actually goes
over the wire.

## One known gap

`bad_args` is not reported. A server that validates arguments before calling the
handler rejects them outside the block, so the call never reaches `record`.
Reporting it anyway would mean reading the difference back out of an error
message, and error strings are not an interface anyone promised to keep. `ok`,
`tool_error` and `crashed` are all exact.

## What leaves your process

Sizes and hashes. Arguments and results do not, and no option turns that on.

## The three rules

1. **Never raise.** Every entry point rescues. Your exception is re-raised
   untouched; ours never reach you.
2. **Never block.** A `Thread` with its own array rather than a sized `Queue` —
   a bounded `Queue#push` blocks when full, which is exactly what must not
   happen on the path a model is waiting on. This drops the oldest entry instead.
3. **Never store customer data.** See above.

## Cross-language consistency

`args_hash` is the first 12 hex characters of the SHA-256 of the
[RFC 8785](https://www.rfc-editor.org/rfc/rfc8785) canonical form of the
arguments. `spec/fixtures/canonical.json` is the shared conformance suite every
MCPulse SDK runs.

Ruby needed three things undone: `Float#to_s` writes `1.0` and `1.0e-07` where
ECMAScript writes `1` and `1e-7`; `JSON.generate` leaves keys in insertion
order; and RFC 8785 sorts keys by UTF-16 code unit while Ruby compares UTF-8
bytes — the two disagree above the BMP, where U+1F680 (the surrogate pair D83D
DE80) sorts *before* U+FFFD.

Symbol-keyed hashes canonicalise identically to string-keyed ones, which matters
because that is what most Ruby MCP servers actually hold.

## Running the tests

```bash
ruby spec/run.rb
```

No gems needed.

## Licence

MIT

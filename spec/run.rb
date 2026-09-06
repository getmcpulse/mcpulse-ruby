# frozen_string_literal: true

# The cross-language contract, plus the parts of the gem that only Ruby can get wrong.
#
# spec/fixtures/canonical.json is the shared conformance suite, copied from
# packages/schemas/fixtures in the mcpulse monorepo. Every
# other MCPulse SDK runs the same file. If it passes in all of them, their hashes are
# interchangeable and a customer running more than one sees one set of numbers rather than several.
#
# Never edit a fixture to make a failure go away — these hashes are in the product's history, and
# rewriting one rewrites what every stored row means.
#
# Plain Ruby rather than RSpec, so the suite runs with nothing but the standard library.

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'digest'
require 'json'
require 'mcpulse'

$passed = 0
$failed = 0

def check(what, expected, actual)
  if expected == actual
    $passed += 1
  else
    $failed += 1
    puts "FAIL #{what}\n  want #{expected.inspect}\n  got  #{actual.inspect}"
  end
end

def refute(what, forbidden, actual)
  if forbidden == actual
    $failed += 1
    puts "FAIL #{what}: got the forbidden value #{forbidden.inspect}"
  else
    $passed += 1
  end
end

def check_raises(what)
  yield
  $failed += 1
  puts "FAIL #{what}: nothing was raised"
rescue StandardError
  $passed += 1
end

# ─── The shared fixtures ─────────────────────────────────────────────────────

fixtures = JSON.parse(File.read(File.expand_path('fixtures/canonical.json', __dir__)))

check('algorithm is pinned', 'sha256/rfc8785/hex12', fixtures['algorithm'])
check('wire version is pinned', 1, fixtures['wire_version'])
check('the full suite is present', true, fixtures['fixtures'].size >= 23)

fixtures['fixtures'].each do |fixture|
  name = fixture['name']
  check("canonical: #{name}", fixture['canonical'], MCPulse::Canonical.canonicalize(fixture['input']))
  check("hash: #{name}", fixture['args_hash'], MCPulse::Hashing.args_hash(fixture['input']))

  # Each fixture's hash must match its own canonical form, so a corrupted file is caught rather
  # than silently agreed with.
  check("self-consistent: #{name}", fixture['args_hash'],
        Digest::SHA256.hexdigest(fixture['canonical'])[0, 12])
end

# ─── ECMAScript Number::toString ─────────────────────────────────────────────

{
  1.0 => '1',            # Ruby writes 1.0
  -0.0 => '0',
  2.5 => '2.5',
  1e21 => '1e+21',       # Ruby writes 1.0e+21
  1e-7 => '1e-7',        # Ruby writes 1.0e-07
  1e-6 => '0.000001',
  0.1 => '0.1',
  5e-324 => '5e-324',
  1.7976931348623157e308 => '1.7976931348623157e+308',
  -1.5e-9 => '-1.5e-9',
  9_007_199_254_740_991 => '9007199254740991',
  1_000_000 => '1000000',
  42 => '42'
}.each do |value, want|
  check("number #{value}", want, MCPulse::Canonical.canonicalize(value))
end

# Integers are doubles, as RFC 8785 requires and as JavaScript does.
check('big integers are doubles',
      MCPulse::Canonical.canonicalize(1.2345678901234567e19),
      MCPulse::Canonical.canonicalize(12_345_678_901_234_567_890))

check_raises('NaN is refused') { MCPulse::Canonical.canonicalize(Float::NAN) }
check_raises('Infinity is refused') { MCPulse::Canonical.canonicalize(Float::INFINITY) }

# ─── Strings and key order ───────────────────────────────────────────────────

check('non-ascii is literal', '"café"', MCPulse::Canonical.canonicalize('café'))
check('emoji is literal', '"🚀"', MCPulse::Canonical.canonicalize('🚀'))
check('html is not escaped', '"a<b>c&d"', MCPulse::Canonical.canonicalize('a<b>c&d'))
check('short escapes', '"\b\t\n\f\r\"\\\\"', MCPulse::Canonical.canonicalize("\b\t\n\f\r\"\\"))
check('other control chars', '"\u0000\u0001\u001f"',
      MCPulse::Canonical.canonicalize("\u0000\u0001\u001f"))

check('sorts at every depth', '{"o":{"a":2,"z":1}}',
      MCPulse::Canonical.canonicalize({ 'o' => { 'z' => 1, 'a' => 2 } }))

# U+1F680 is the surrogate pair D83D DE80, so it sorts before U+FFFD. Ruby's own byte ordering
# puts it after.
check('utf-16 key order', %({"a":4,"é":3,"🚀":2,"\uFFFD":1}),
      MCPulse::Canonical.canonicalize({ "\uFFFD" => 1, '🚀' => 2, 'é' => 3, 'a' => 4 }))

check('array order is left alone', '[2,1]', MCPulse::Canonical.canonicalize([2, 1]))

# Symbol keys are what a Ruby MCP server most often has, and must canonicalise identically.
check('symbol keys match string keys',
      MCPulse::Canonical.canonicalize({ 'b' => 2, 'a' => 1 }),
      MCPulse::Canonical.canonicalize({ b: 2, a: 1 }))

# ─── args_hash ───────────────────────────────────────────────────────────────

# A no-argument tool is an ordinary call. Sharing the failure sentinel would make every such tool
# look broken.
check('absent args are {}', MCPulse::Hashing.args_hash({}), MCPulse::Hashing.args_hash(nil))
refute('absent args are not the sentinel', MCPulse::Hashing::UNHASHABLE, MCPulse::Hashing.args_hash(nil))

circular = {}
circular['self'] = circular
check('circular gets the sentinel', MCPulse::Hashing::UNHASHABLE, MCPulse::Hashing.args_hash(circular))
check('NaN gets the sentinel', MCPulse::Hashing::UNHASHABLE,
      MCPulse::Hashing.args_hash({ 'n' => Float::NAN }))

hash = MCPulse::Hashing.args_hash({ 'q' => 'anything' })
check('twelve characters', 12, hash.length)
check('lowercase hex', hash, hash.downcase)

id = MCPulse::Hashing.new_session_id
check('session id shape', true, id.start_with?('s_') && id.length == 14)
refute('session ids differ', id, MCPulse::Hashing.new_session_id)

# ─── Emptiness ───────────────────────────────────────────────────────────────

def text_result(value)
  { 'content' => [{ 'type' => 'text', 'text' => value }] }
end

check('nil is empty', true, MCPulse::Emptiness.empty_result?(nil))
check('no parts is empty', true, MCPulse::Emptiness.empty_result?({ 'content' => [] }))
check('a serialised empty list is empty', true, MCPulse::Emptiness.empty_result?(text_result('[]')))
check('blank text is empty', true, MCPulse::Emptiness.empty_result?(text_result('   ')))
check('prose is not empty', false, MCPulse::Emptiness.empty_result?(text_result('no rows found')))

# 0 and false are results, not absences. Counting them as empty would report working tools as
# broken.
check('zero is an answer', false, MCPulse::Emptiness.empty_result?(text_result('0')))
check('false is an answer', false, MCPulse::Emptiness.empty_result?(text_result('false')))

# The {"result" => …} envelope some SDKs add must not hide an empty answer.
check('the result envelope is opened', true,
      MCPulse::Emptiness.empty_result?({ 'structuredContent' => { 'result' => '[]' } }))

# ─── Recording ───────────────────────────────────────────────────────────────

recorded = []
MCPulse::Stream.sink = ->(payload) { recorded << payload }
MCPulse::Stream.reset!
MCPulse.configure(key: 'mp_test_key', endpoint: 'http://127.0.0.1:1')

result = MCPulse.record('echo', { 'text' => 'sensitive-argument-value' }, client_name: 'test-client') do
  text_result('hello')
end

calls = recorded.select { |p| p[:type] == 'call' }
check('one call recorded', 1, calls.size)
check('tool name', 'echo', calls[0][:tool_name])
check('outcome', 'ok', calls[0][:outcome])
check('wire version', 1, calls[0][:v])
check('client name', 'test-client', calls[0][:client_name])
check('result passes through', 'hello', result['content'][0]['text'])
check('is_empty', false, calls[0][:is_empty])
check('args_hash is twelve characters', 12, calls[0][:args_hash].length)
check('no argument value on the wire', false, JSON.generate(recorded).include?('sensitive-argument-value'))

# Argument order must not change the hash.
recorded.clear
MCPulse.record('two', { 'a' => 1, 'b' => 2 }) { text_result('x') }
MCPulse.record('two', { 'b' => 2, 'a' => 1 }) { text_result('x') }
calls = recorded.select { |p| p[:type] == 'call' }
check('reordered arguments hash the same', calls[0][:args_hash], calls[1][:args_hash])

# A raising handler is crashed, and the exception still reaches the server.
recorded.clear
raised = false
begin
  MCPulse.record('explode') { raise 'boom' }
rescue RuntimeError
  raised = true
end
check('the exception still reaches the server', true, raised)
check('outcome is crashed', 'crashed', recorded.first[:outcome])

# An isError result is a tool error, not a crash.
recorded.clear
MCPulse.record('failing') { { 'content' => [], 'isError' => true } }
check('outcome is tool_error', 'tool_error', recorded.first[:outcome])

# An empty answer is flagged.
recorded.clear
MCPulse.record('nothing') { text_result('[]') }
check('an empty result is flagged', true, recorded.first[:is_empty])

# Startup, once.
recorded.clear
MCPulse.record_startup([{ 'name' => 'echo', 'inputSchema' => { 'type' => 'object' } }], client_name: 'test-client')
MCPulse.record_startup([{ 'name' => 'echo' }])
check('startup is sent once', 1, recorded.size)
check('startup type', 'startup', recorded.first[:type])
check('schema_bytes is measured', true, recorded.first[:tools][0][:schema_bytes].positive?)

# Two configurations for the same destination are one session, not two.
#
# The bug this guards against is invisible in a stdio server and fatal in an HTTP one: a server
# configured per request would open a session per request, so a retry could never be detected and
# first-call success would report a perfect score however badly the server was doing.
MCPulse.configure(key: 'mp_test_key', endpoint: 'http://127.0.0.1:1')
first_session = MCPulse.session_id
MCPulse.configure(key: 'mp_test_key', endpoint: 'http://127.0.0.1:1')
check('the same destination is one session', first_session, MCPulse.session_id)

# Two keys are two customers. Merging them would file one customer's calls under another's.
MCPulse.configure(key: 'mp_other_key', endpoint: 'http://127.0.0.1:1')
refute('different keys are different sessions', first_session, MCPulse.session_id)

# Configured off means nothing is recorded, and the handler still runs.
recorded.clear
MCPulse.configure(key: '')
check('a disabled handler still runs', 'hello', MCPulse.record('echo') { text_result('hello') }['content'][0]['text'])
check('an empty key records nothing', 0, recorded.size)

MCPulse::Stream.sink = nil

puts
puts "#{$passed} passed, #{$failed} failed"
exit($failed.zero? ? 0 : 1)

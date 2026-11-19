# Checks the Ruby backports + Win32 stand-ins of compat.rb by first REMOVING the modern methods, as in Ruby 1.9.
# Run: ruby test_backports.rb   (needs the mocks of test.rb, so it loads that file's top part)
require 'tmpdir'
$failed = false
def check(name, ok); puts((ok ? 'ok   ' : 'FAIL ') + name); $failed = true unless ok; end
def drop(k, *names); names.each { |n| k.send(:remove_method, n) rescue (k.send(:undef_method, n) rescue nil) }; end
drop(Enumerable, :sum, :to_h, :filter_map, :tally, :each_entry)
drop(Array, :sum, :to_h, :filter, :append, :prepend, :difference, :union, :intersection, :intersect?, :dig, :bsearch, :filter_map, :tally)
drop(Hash, :dig, :to_h, :transform_values, :transform_values!, :transform_keys, :transform_keys!, :slice, :except, :compact, :compact!, :filter, :fetch_values, :filter_map, :sum)
drop(String, :delete_prefix, :delete_suffix, :casecmp?, :unpack1, :match?, :b, :scrub, :+@, :-@)
drop(Symbol, :start_with?, :end_with?); drop(Regexp, :match?); drop(Struct, :to_h)
drop(Comparable, :clamp); drop(Numeric, :positive?, :negative?); drop(Integer, :digits, :bit_length, :pow)
drop(Kernel, :itself, :then, :yield_self)
module System; def self.puts(m); $stdout.puts m; end; end rescue nil
module Win32API_Impl; end
class Win32API; def initialize(*a); end; def call(*a); 0; end; end
module DL; end
load File.join(File.dirname(__FILE__), 'compat.rb')
check 'sum', [1, 2, 3].sum == 6 && [1, 2].sum { |x| x * 2 } == 6
check 'to_h', [[1, 2]].to_h == { 1 => 2 } && { 1 => 2 }.to_h == { 1 => 2 }
check 'filter_map/tally', [1, 2, 3].filter_map { |x| x * 2 if x > 1 } == [4, 6] && %w[a a b].tally == { 'a' => 2, 'b' => 1 }
check 'dig', { a: [{ b: 5 }] }.dig(:a, 0, :b) == 5 && [[1, [2]]].dig(0, 1, 0) == 2
check 'hash transforms', { a: 1 }.transform_values { |v| v + 1 } == { a: 2 } && { a: 1 }.transform_keys { |k| k.to_s } == { 'a' => 1 }
check 'slice/except/compact', { a: 1, b: nil }.slice(:a) == { a: 1 } && { a: 1, b: 2 }.except(:a) == { b: 2 } && { a: 1, b: nil }.compact == { a: 1 }
check 'string helpers', 'foobar'.delete_prefix('foo') == 'bar' && 'foobar'.delete_suffix('bar') == 'foo' && 'Ab'.casecmp?('aB') && 'x'.match?(/x/)
check 'unary plus/minus', (+'a') == 'a' && (-'a').frozen?
check 'symbol', :abc.start_with?('a') && :abc.end_with?('c')
check 'clamp', 5.clamp(1, 3) == 3 && 0.clamp(1..3) == 1 && 2.clamp(1, 3) == 2
check 'integer', 123.digits == [3, 2, 1] && 8.bit_length == 4 && 2.pow(10) == 1024 && 5.positive? && -5.negative?
check 'then/itself', 5.then { |x| x + 1 } == 6 && 5.itself == 5
check 'array sets', [1, 2, 3].difference([2]) == [1, 3] && [1].union([2]) == [1, 2] && [1, 2].intersection([2]) == [2] && [1, 2].intersect?([2])
check 'bsearch', [1, 3, 5, 7].bsearch { |x| x >= 4 } == 5
check 'struct to_h', Struct.new(:a).new(1).to_h == { a: 1 }
check 'clock_gettime', Process.clock_gettime(Process::CLOCK_MONOTONIC).is_a?(Float)
Dir.mktmpdir do |d|
  ini = File.join(d, 'g.ini')
  File.write(ini, "[Game]\r\nTitle=Hello\r\nLevel=7\r\n; c\r\n[Other]\r\nX=1\r\n")
  buf = "\0" * 64
  n = Win32API_Impl::Kernel32::GetPrivateProfileStringA.new.call(['Game', 'Title', 'def', buf, 64, ini])
  check 'GetPrivateProfileString', n == 5 && buf[0, 5] == 'Hello' && buf.getbyte(5) == 0
  buf2 = "\0" * 64
  Win32API_Impl::Kernel32::GetPrivateProfileStringA.new.call(['Game', 'Missing', 'dflt', buf2, 64, ini])
  check 'default value', buf2[0, 4] == 'dflt'
  check 'GetPrivateProfileInt', Win32API_Impl::Kernel32::GetPrivateProfileIntA.new.call(['Game', 'Level', 0, ini]) == 7
  Win32API_Impl::Kernel32::WritePrivateProfileStringA.new.call(['Game', 'Level', '9', ini])
  Win32API_Impl::Kernel32::WritePrivateProfileStringA.new.call(['New', 'K', '4', ini])
  check 'WritePrivateProfileString', Win32API_Impl::Kernel32::GetPrivateProfileIntA.new.call(['Game', 'Level', 0, ini]) == 9 &&
    Win32API_Impl::Kernel32::GetPrivateProfileIntA.new.call(['Other', 'X', 0, ini]) == 1 &&
    Win32API_Impl::Kernel32::GetPrivateProfileIntA.new.call(['New', 'K', 5, ini]) == 4
  wbuf = "\0" * 64
  Win32API_Impl::Kernel32::GetPrivateProfileStringW.new.call(['Game', 'Title', '', wbuf, 32, ini])
  check 'wide string result', wbuf.unpack('v5').pack('U*') == 'Hello'
end
check 'timers', Win32API_Impl::Kernel32::GetTickCount.new.call([]) > 0 && Win32API_Impl::Winmm::TimeGetTime.new.call([]) > 0
exit($failed ? 1 : 0)

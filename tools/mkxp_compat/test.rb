# Headless check of compat.rb against a mock of the core's Win32API stand-ins. Run: ruby test.rb
$out = []
module System; def self.puts(m); $out << m; end; end
module Scancodes; WIN32 = { :A => 0x41, :SHIFT => 0x10, :RETURN => 0x0D }; end
module Input; def self.asyncKeyState(v); v == 0x41 ? 1 : 0; end; end
module Win32API_Impl
  module User32
    class GetKeyboardState   # same body as the core's scripts/preload/win32_wrap.rb
      def call(args)
        out_states = args[0]
        Scancodes::WIN32.each { |_n, val| out_states[val] = Input.asyncKeyState(val) > 0 ? 0x80 : 0 }
        1
      end
    end
  end
end
class Win32API   # same lookup and tolerance as the core's
  def initialize(dll, func, *a)
    @dll = dll; @func = func
    d = dll.sub(/\.dll\z/i, '').capitalize
    @impl = Win32API_Impl.const_defined?(d) && Win32API_Impl.const_get(d).const_defined?(func) ? Win32API_Impl.const_get(d).const_get(func).new : nil
  end
  def call(*args)
    return @impl.call(args) if @impl
    System.puts("[Win32API] [#{@dll}:#{@func}] #{args}")
    0
  end
end
module DL; end
load File.join(File.dirname(__FILE__), 'compat.rb')

def check(name, ok)
  puts "#{ok ? 'ok  ' : 'FAIL'} #{name}"
  $failed = true unless ok
end

# 1. LonaRPG's Full Input script
state = DL::CPtr.new(DL.malloc(256), 256)
gks = Win32API.new('user32.dll', 'GetKeyboardState', 'I', 'I')
check 'GetKeyboardState.call(@state.to_i) returns 1', gks.call(state.to_i) == 1
check 'key A reads as down', (state[0x41] & (0x8 << 4)) == (0x8 << 4)
check 'key SHIFT reads as up', (state[0x10] & (0x8 << 4)) == 0
# 2. malloc'd addresses are distinct, ptr[i]= and ptr[i,len]
a = DL::CPtr.malloc(8); b = DL::CPtr.malloc(8)
check 'distinct addresses', a.to_i != b.to_i
a[0] = 7; a[1, 2] = "\x01\x02"
check 'byte write/read', a[0] == 7 && a[1] == 1 && a[2] == 2 && a[1, 2] == "\x01\x02"
# 3. an ordinary integer is not mistaken for a buffer
check 'plain integer untouched', Win32API.new('user32', 'Unknown', 'I', 'I').call(5) == 0
# 4. dlopen route
h = DL.dlopen('user32')
f = h['GetKeyboardState', 'IP']
state2 = DL::CPtr.malloc(256)
check 'DL.dlopen function call', f.call(state2.to_i) == 1 && state2[0x41] == 0x80
# 5. Importer route
module MyUser32
  extend DL::Importer
  dlload 'user32'
  extern 'int GetKeyboardState(void*)'
end
state3 = DL::CPtr.malloc(256)
check 'extern function call', MyUser32.GetKeyboardState(state3.to_i) == 1 && state3[0x41] == 0x80
# 6. unknown library function: tolerated and logged once
DL.dlopen('kernel32')['Nope'].call(1)
check 'unknown function tolerated', $out.any? { |m| m.include?('kernel32:Nope') }
check 'Fiddle alias', Fiddle::CPtr == DL::CPtr
# 7. loading compat.rb twice must not recurse
load File.join(File.dirname(__FILE__), 'compat.rb')
check 'second load is harmless', Win32API.new('user32.dll', 'GetKeyboardState', 'I', 'I').call(DL::CPtr.malloc(256).to_i) == 1
# 8. the call-depth trace names the recursing methods
$out.clear
load File.join(File.dirname(__FILE__), 'trace.rb')
module JSON; @json = '[[[[ hello ]]]]'; @index = 4; end
def nex_runaway(n); nex_runaway(n + 1) if n < 3500; end
nex_runaway(0)
set_trace_func(nil)
check 'trace shows the JSON text', $out.any? { |m| m.include?('JSON text around the index') }
check 'trace reports the runaway method', $out.any? { |m| m.include?('nex_runaway') } && $out.any? { |m| m.include?('last calls') }

# Windows-style text mode: "\r\n" is read as "\n" unless the file is opened binary.
require 'tmpdir'
tmp = File.join(Dir.tmpdir, 'nex_crlf_test.json')
File.open(tmp, 'wb') { |f| f.write("[\r\n1,\r\n2\r\n]") }
check 'plain File.open read drops \\r', File.open(tmp).read == "[\n1,\n2\n]"
check 'Kernel#open read drops \\r', open(tmp).read == "[\n1,\n2\n]"
check 'File.read drops \\r', File.read(tmp) == "[\n1,\n2\n]"
check 'File.open "r" drops \\r', File.open(tmp, 'r').read == "[\n1,\n2\n]"
check 'File.open with block drops \\r', File.open(tmp) { |f| f.read } == "[\n1,\n2\n]"
check 'File.open "rb" keeps \\r', File.open(tmp, 'rb').read == "[\r\n1,\r\n2\r\n]"
check 'File.binread keeps \\r', File.binread(tmp) == "[\r\n1,\r\n2\r\n]"
check 'readlines drops \\r', File.open(tmp).readlines.first == "[\n"
File.open(tmp, 'wb') { |f| f.write(Marshal.dump([1, "a\r\nb"])) }
check 'Marshal through "rb" is intact', Marshal.load(File.open(tmp, 'rb')) == [1, "a\r\nb"]
File.open(tmp, 'w') { |f| f.write("x\ny") }
check 'writing still works', File.read(tmp) == "x\ny"
File.delete(tmp)
exit($failed ? 1 : 0)

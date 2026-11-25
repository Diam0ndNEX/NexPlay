# NexPlay 8.20.0: compat.rb on mkxp core v27+, whose preload already has DL.malloc / DL::CPtr on a FakeHeap.
# Run: ruby test_core_dl.rb
$out = []
module System; def self.puts(m); $out << m; end; end
module Scancodes; WIN32 = { :A => 0x41 }; end
module Input; def self.asyncKeyState(v); v == 0x41 ? 1 : 0; end; end
module Win32API_Impl
  module FakeHeap   # as in the core's win32_wrap.rb (v27)
    BASE = 0x7F00_0000
    @blocks = {}
    @next_address = BASE
    def self.alloc(bytes); a = @next_address; @next_address += 0x1000; @blocks[a] = bytes.dup.force_encoding('BINARY'); a; end
    def self.block(a); @blocks[a]; end
  end
  module User32
    class GetKeyboardState   # v27: writes into the FakeHeap block of an address
      def call(args)
        out = args[0]
        out = Win32API_Impl::FakeHeap.block(out) if out.is_a?(Integer)
        Scancodes::WIN32.each { |_n, val| out.setbyte(val, Input.asyncKeyState(val) > 0 ? 0x80 : 0) }
        1
      end
    end
  end
end
class Win32API
  def initialize(dll, func, *a); @dll = dll; @func = func
    @impl = func == 'GetKeyboardState' ? Win32API_Impl::User32::GetKeyboardState.new : nil; end
  def call(*args); return @impl.call(args) if @impl; 0; end
end
module DL   # the core's v27 DL
  def self.malloc(size); Win32API_Impl::FakeHeap.alloc("\0" * size.to_i); end
  class CPtr
    def initialize(address, size = 0); @address = address.to_i; @bytes = Win32API_Impl::FakeHeap.block(@address) || ("\0" * size.to_i); end
    def to_i; @address; end
    def [](i); b = @bytes.getbyte(i) || 0; b >= 0x80 ? b - 0x100 : b; end
    def []=(i, v); @bytes.setbyte(i, v.to_i & 0xff); end
  end
end
load File.join(File.dirname(__FILE__), 'compat.rb')
failed = false
check = lambda { |name, ok| puts "#{ok ? 'ok  ' : 'FAIL'} #{name}"; failed ||= !ok }
ptr = DL::CPtr.new(DL.malloc(256), 256)
check.call('malloc stays on the core heap', ptr.to_i < DL::NEX_BASE && Win32API_Impl::FakeHeap.block(ptr.to_i))
Win32API.new('user32', 'GetKeyboardState', ['p'], 'i').call(ptr.to_i)
check.call('GetKeyboardState reaches the buffer (Hime keyboard)', ptr[0x41] == -128)
check.call('CPtr#size added', ptr.size == 256)
check.call('CPtr#to_s added', ptr.to_s(2) == "\0\0")
check.call('CPtr#null? added', ptr.null? == false)
check.call('Importer still there', defined?(DL::Importer) ? true : false)
check.call('logged once', $out.any? { |l| l.include?('come from the mkxp core') })
exit(failed ? 1 : 0)

# NexPlay stand-ins for the Ruby 1.9 DL / Fiddle libraries that RPG Maker games use to talk to Windows.
# The mkxp core has no DL, so scripts that call DL.malloc, DL::CPtr, DL.dlopen, DL::Importer (extern) or Fiddle
# died at load time. Here a "pointer" is a plain byte array, and every library function goes through Win32API,
# whose stand-ins answer the calls the core knows and return 0 (logged once) for the rest.
# Plain Ruby 1.8/1.9 syntax on purpose: the core runs the game's own Ruby version.
module DL
  NEX_BASE = 0x600000000000 unless const_defined?(:NEX_BASE)
  @nex_mem = {}
  @nex_next = NEX_BASE
  @nex_logged = {}

  class << self
    def nex_log(message)
      @nex_logged ||= {}
      return if @nex_logged[message]
      @nex_logged[message] = true
      begin
        System.puts("[NexPlay compat] " + message)
      rescue StandardError, NameError
      end
    end

    def malloc(size, *rest)
      size = size.to_i
      @nex_next += ((size + 15) / 16) * 16 + 16
      @nex_mem[@nex_next] = Array.new(size, 0)
      @nex_next
    end

    def free(addr)
      @nex_mem.delete(addr.to_i)
      0
    end

    def nex_buffer(addr)
      @nex_mem[addr.to_i]
    end

    # The pointer object for an address this module handed out, else nil.
    def nex_pointer(addr)
      buffer = @nex_mem[addr.to_i]
      buffer ? DL::CPtr.new(addr.to_i, buffer.size) : nil
    end

    def dlopen(name, *rest)
      DL::Handle.new(name)
    end
  end

  unless const_defined?(:CPtr)
    class CPtr
      def self.malloc(size, free = nil)
        new(DL.malloc(size), size)
      end

      def initialize(addr = 0, size = 0, free = nil)
        @addr = addr.to_i
        @size = size.to_i
      end

      def to_i; @addr; end
      def to_int; @addr; end
      def size; @size; end
      def null?; @addr == 0; end

      def [](index, len = nil)
        buffer = DL.nex_buffer(@addr) || []
        return(buffer[index] || 0) if len.nil?
        (buffer[index, len] || []).pack('C*')
      end

      def []=(index, a, b = nil)
        buffer = DL.nex_buffer(@addr)
        return b.nil? ? a : b unless buffer
        if b.nil?
          buffer[index] = a.to_i
          a
        else
          bytes = b.respond_to?(:unpack) ? b.unpack('C*') : []
          bytes.each_with_index { |byte, i| buffer[index + i] = byte }
          b
        end
      end

      def to_s(len = nil)
        buffer = DL.nex_buffer(@addr) || []
        (len ? buffer[0, len] : buffer).to_a.pack('C*')
      end

      def free; DL.free(@addr); end
    end
  end
  PtrData = CPtr unless const_defined?(:PtrData)
  Pointer = CPtr unless const_defined?(:Pointer)

  # A library function. It runs through Win32API, so what the core can answer it answers.
  unless const_defined?(:Function)
    class Function
      def initialize(target, args = nil, ret = nil, *rest)
        if target.respond_to?(:nex_lib)
          @lib = target.nex_lib
          @name = target.nex_name
        else
          @lib = 'user32'
          @name = target.to_s
        end
      end

      def nex_lib; @lib; end
      def nex_name; @name; end

      def call(*args)
        @api ||= Win32API.new(@lib, @name, nil, nil)
        @api.call(*args)
      end
      alias_method :[], :call
    end
  end

  unless const_defined?(:Handle)
    class Handle
      def initialize(lib = nil, flags = nil)
        @lib = lib.to_s
      end

      def sym(name, signature = nil)
        DL.nex_log("library function #{@lib}:#{name} goes through Win32API")
        DL::Function.new(Struct.new(:nex_lib, :nex_name).new(@lib, name.to_s))
      end
      alias_method :[], :sym

      def close; 0; end
    end
  end

  # extend DL::Importable / DL::Importer / Fiddle::Importer; dlload "user32"; extern "int GetKeyState(int)"
  unless const_defined?(:Importable)
    module Importable
      def dlload(*libs)
        @nex_libs = libs.map { |lib| lib.to_s }
        nil
      end

      def extern(signature, *rest)
        text = signature.to_s
        match = text.match(/(\w+)\s*\(/)
        return nil unless match
        name = match[1]
        lib = (@nex_libs && @nex_libs.first) || 'user32'
        function = DL::Function.new(Struct.new(:nex_lib, :nex_name).new(lib, name))
        singleton = (class << self; self; end)
        singleton.send(:define_method, name) { |*args| function.call(*args) }
        function
      end

      def typealias(*args); nil; end
      def struct(*args); nil; end
      def union(*args); nil; end
      def callback(*args); nil; end
      def import_function(name, *args)
        extern(name.to_s + '()')
      end
    end
  end
  Importer = Importable unless const_defined?(:Importer)
end

# Fiddle is DL's newer name.
Fiddle = DL unless defined?(Fiddle)

# A DL buffer passed to a Win32API call as its address is handed over as the pointer object, so the core's stand-ins
# (GetKeyboardState fills the buffer by index) can write into it.
begin
  Win32API.class_eval do
    alias_method :nex_call_before_dl, :call
    def call(*args)
      args = args.map do |arg|
        pointer = (arg.is_a?(Integer) && arg >= DL::NEX_BASE) ? DL.nex_pointer(arg) : nil
        pointer || arg
      end
      nex_call_before_dl(*args)
    end
  end
rescue StandardError, NameError
end

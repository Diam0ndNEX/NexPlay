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
    # Guard: loading this file twice must not alias the wrapper to itself (endless recursion).
    next if method_defined?(:nex_call_before_dl)
    alias_method :nex_call_before_dl, :call
    def call(*args)
      if @dll.to_s =~ /kgl2\.klib\z/i
        return NexKGL.call(@func.to_s, args)
      end
      args = args.map do |arg|
        pointer = (arg.is_a?(Integer) && arg >= DL::NEX_BASE) ? DL.nex_pointer(arg) : nil
        pointer || arg
      end
      nex_call_before_dl(*args)
    end
  end
rescue StandardError, NameError
end

# Windows opens a file in text mode by default: "\r\n" is read as "\n". Games written on Windows rely on it (a JSON
# or text file saved with Windows line endings, read by a hand-written parser that only knows "\n"). Everywhere else a
# plain read keeps the "\r", and such a parser then sees an unknown character. So a file opened for reading without
# "b" (binary) is opened in text mode here, as on Windows; "rb" and every write mode are untouched.
begin
  # Plain Ruby 1.9 syntax on purpose: the core parses this file with a 1.9 parser (no **opts, no prepend).
  module NexTextMode
    def self.mode_for(mode)
      return 'rt' if mode.nil?
      return mode unless mode.is_a?(String)
      return mode unless mode =~ /\Ar(?![^:]*[bt+])/
      mode.sub(/\Ar/, 'rt')
    end

    # Does this File.new/File.open call read in text mode (no "b", no "+", not a write mode)?
    def self.text_read?(args)
      return false if args.empty? || args[0].is_a?(Integer)
      opts = args.last.is_a?(Hash) ? args.last : nil
      return false if opts && !options_ok?(opts)
      positional = opts ? args[0...-1] : args
      mode = positional[1]
      return true if mode.nil?
      return false unless mode.is_a?(String)
      !!(mode =~ /\Ar(?![^:]*[b+])/)
    end

    # Some builds of the core keep the "\r" even in "rt" mode, so the text is also cleaned after reading.
    def self.clean(text)
      return text unless text.is_a?(String)
      return text unless text.index("\r")
      text.gsub("\r\n", "\n")
    rescue Exception
      text
    end

    def self.options_ok?(opts)
      !(opts.key?(:mode) || opts.key?(:binmode) || opts.key?(:textmode) || opts.key?(:newline) ||
        opts.key?(:universal_newline) || opts.key?(:crlf_newline))
    end

    # Arguments of File.new / File.open: (path, mode = nil, perm = nil, options = {}).
    def self.file_args(args)
      return args if args.empty? || args[0].is_a?(Integer)
      opts = args.last.is_a?(Hash) ? args.last : nil
      return args if opts && !options_ok?(opts)
      positional = opts ? args[0...-1] : args.dup
      return args if positional.length > 2
      mode = positional[1]
      return args unless mode.nil? || mode.is_a?(String)
      positional[1] = mode_for(mode)
      opts ? positional + [opts] : positional
    end

    # Modern Ruby needs a trailing options hash flagged as keywords; Ruby 1.9 has no such thing.
    def self.keywords(hash)
      Hash.respond_to?(:ruby2_keywords_hash) ? Hash.ruby2_keywords_hash(hash) : hash
    end

    # Arguments of IO.read / File.read: (path, length = nil, offset = nil, options = {}).
    def self.read_args(args)
      return args if args.empty? || args[0].is_a?(Integer)
      opts = args.last.is_a?(Hash) ? args.last : nil
      return args if opts && !options_ok?(opts)
      return args if opts && opts.key?(:mode)
      if opts
        args[0...-1] + [keywords({ :mode => 'rt' }.merge(opts))]
      else
        args + [keywords({ :mode => 'rt' })]
      end
    end
  end

  unless File.private_method_defined?(:nex_initialize_before_text)
    File.class_eval do
      alias_method :nex_initialize_before_text, :initialize
      def initialize(*args, &block)
        @nex_text_read = NexTextMode.text_read?(args)
        nex_initialize_before_text(*NexTextMode.file_args(args), &block)
      end
      ruby2_keywords(:initialize) if respond_to?(:ruby2_keywords, true)
    end
  end

  unless File.private_method_defined?(:nex_read_before_clean) || File.method_defined?(:nex_read_before_clean)
    File.class_eval do
      alias_method :nex_read_before_clean, :read
      alias_method :nex_gets_before_clean, :gets
      alias_method :nex_readlines_before_clean, :readlines
      def read(*args)
        text = nex_read_before_clean(*args)
        @nex_text_read && (args.empty? || args[0].nil?) ? NexTextMode.clean(text) : text
      end
      def gets(*args)
        text = nex_gets_before_clean(*args)
        @nex_text_read ? NexTextMode.clean(text) : text
      end
      def readlines(*args)
        lines = nex_readlines_before_clean(*args)
        @nex_text_read ? lines.map { |l| NexTextMode.clean(l) } : lines
      end
    end
  end

  unless IO.respond_to?(:nex_read_before_text)
    class << IO
      alias_method :nex_read_before_text, :read
      def read(*args)
        text = nex_read_before_text(*NexTextMode.read_args(args))
        (args.length == 1 || (args.length == 2 && args[1].is_a?(Hash) && NexTextMode.options_ok?(args[1]))) ? NexTextMode.clean(text) : text
      end
      ruby2_keywords(:read) if respond_to?(:ruby2_keywords, true)
    end
  end
rescue StandardError, NameError, ArgumentError
end

# Real RGSS takes any value for a true/false property (`sprite.visible = some_object`, `window.visible = 1`); the core
# raises "TypeError: Argument 0: Expected bool" for anything but true/false/nil. The core already wraps some setters
# (Font bold/italic/shadow/outline, Sprite mirror/pattern_tile/invert, Window stretch/active/pause/arrows_visible,
# Tilemap visible); the visible= of Sprite, Plane, Window and Viewport is not among them. Same wrapping, same guard:
# one alias per setter, so a second load can't alias the wrapper to itself.
begin
  %w[Sprite Plane Window Viewport Tilemap].each do |class_name|
    next unless Object.const_defined?(class_name)
    klass = Object.const_get(class_name)
    next unless klass.method_defined?('visible=')
    next if klass.method_defined?('nex_bool_orig_visible=')
    klass.class_eval do
      alias_method 'nex_bool_orig_visible=', 'visible='
      define_method('visible=') { |value| send('nex_bool_orig_visible=', value ? true : false) }
    end
  end
  %w[default_bold default_italic default_shadow default_outline].each do |prop|
    next unless defined?(Font) && Font.respond_to?(prop + '=')
    orig = 'nex_bool_orig_' + prop + '='
    next if Font.respond_to?(orig)
    Font.singleton_class.class_eval do
      alias_method orig, prop + '='
      define_method(prop + '=') { |value| send(orig, value ? true : false) }
    end
  end
rescue StandardError, NameError
end

# Windows runs Ruby 1.9 with a text encoding set for the system; a game reading its UTF-8 text files and calling
# encode("utf-8") on them works there. When this build starts with a binary default encoding, the same call fails
# ("\xE5" from ASCII-8BIT to UTF-8). A binary or ASCII default is raised to UTF-8; the encodings are logged either way.
begin
  if Encoding.default_external == Encoding::ASCII_8BIT || Encoding.default_external == Encoding::US_ASCII
    Encoding.default_external = Encoding::UTF_8
  end
  DL.nex_log('encodings: external ' + Encoding.default_external.to_s + ', internal ' + Encoding.default_internal.inspect)
rescue StandardError, NameError
end

# Khas Graphics Library (System/KGL2.klib), the Windows DLL behind Khas Ultra Lighting (used by LonaRPG and others).
# The DLL draws into a bitmap's pixel memory through the bitmap's object address, which cannot be done here, so its
# few functions are done with the player's own drawing instead. The game keeps its darkness in a "framebuffer" bitmap
# shown by a sprite with SUBTRACT blending; the DLL's light shader takes each light away from that darkness. Same result
# with sprites: the framebuffer keeps the ambient colour (kglClear), and every light is an ADD-blended sprite just
# below the darkness sprite, as strong as the darkness sprite is opaque. Shadows (kglShadowShaderH/V/W) erase the
# part of a light's own bitmap that lies behind a wall as seen from the light's centre. Soft shadows are not done.
# Ruby 1.9 only knows Integer#[](bit) and defines it on Fixnum/Bignum (not Integer). Newer Ruby (2.7+)
# also takes (start, len) and a Range, and mods written for it call e.g. `5[0, 8]`.
%w(Integer Fixnum Bignum).each do |nex_cname|
  begin
    next unless Object.const_defined?(nex_cname)
    nex_klass = Object.const_get(nex_cname)
    next unless nex_klass.instance_methods(false).map { |m| m.to_s }.include?('[]')
    next if nex_klass.method_defined?(:nex_bit_ref_orig)
    nex_klass.class_eval do
      alias_method :nex_bit_ref_orig, :[]
      def [](*args)
        if args.length == 1 && !args[0].is_a?(Range)
          return nex_bit_ref_orig(args[0])
        end
        if args.length == 2
          pos = args[0].to_i
          len = args[1].to_i
          return (self >> pos) & ((1 << len) - 1)
        end
        if args.length == 1
          r = args[0]
          pos = r.first.to_i
          last = r.last
          return (self >> pos) if last.nil?
          len = last.to_i - pos + (r.exclude_end? ? 0 : 1)
          return (self >> pos) & ((1 << len) - 1)
        end
        raise ArgumentError, 'wrong number of arguments (' + args.length.to_s + ' for 1..2)'
      end
    end
  rescue Exception => e
    DL.nex_log('Integer#[] shim failed: ' + e.message)
  end
end

# ---------------------------------------------------------------------------------------------
# Safety net 1: newer Ruby methods. The core embeds Ruby 1.9, but mods and newer scripts are
# written for 2.x/3.x. Every method below is only added when it is missing (plain 1.9 syntax).
# ---------------------------------------------------------------------------------------------
module NexBackport
  def self.define(klass, name, &body)
    if klass.method_defined?(name) || klass.private_method_defined?(name)
      owner = klass.instance_method(name).owner rescue klass
      return unless owner == Enumerable && klass != Enumerable
    end
    klass.send(:define_method, name, &body)
  rescue Exception => e
    DL.nex_log('backport ' + klass.to_s + '#' + name.to_s + ' failed: ' + e.message) if defined?(DL)
  end
end

module Enumerable
  NexBackport.define(self, :sum) do |*init, &blk|
    acc = init.empty? ? 0 : init[0]
    each { |x| acc = acc + (blk ? blk.call(x) : x) }
    acc
  end
  NexBackport.define(self, :to_h) do |&blk|
    h = {}
    each do |x|
      pair = blk ? blk.call(x) : x
      h[pair[0]] = pair[1]
    end
    h
  end
  NexBackport.define(self, :filter_map) do |&blk|
    out = []
    each { |x| v = blk.call(x); out << v if v }
    out
  end
  NexBackport.define(self, :tally) do
    h = Hash.new(0)
    each { |x| h[x] += 1 }
    h
  end
  NexBackport.define(self, :each_entry) { |&blk| each(&blk) }
end

class Array
  NexBackport.define(self, :filter) { |&blk| select(&blk) }
  NexBackport.define(self, :append) { |*a| push(*a) }
  NexBackport.define(self, :prepend) { |*a| unshift(*a) }
  NexBackport.define(self, :difference) { |*o| o.inject(self) { |m, x| m - x } }
  NexBackport.define(self, :union) { |*o| o.inject(self) { |m, x| m | x } }
  NexBackport.define(self, :intersection) { |*o| o.inject(self) { |m, x| m & x } }
  NexBackport.define(self, :intersect?) { |o| !(self & o).empty? }
  NexBackport.define(self, :dig) do |idx, *rest|
    v = self[idx]
    rest.empty? || v.nil? ? v : v.dig(*rest)
  end
  NexBackport.define(self, :bsearch) do |&blk|
    lo = 0
    hi = size
    found = nil
    while lo < hi
      mid = (lo + hi) / 2
      r = blk.call(self[mid])
      if r == true
        found = self[mid]
        hi = mid
      elsif r == false || r.nil?
        lo = mid + 1
      elsif r == 0
        found = self[mid]
        break
      elsif r < 0
        hi = mid
      else
        lo = mid + 1
      end
    end
    found
  end
end

class Hash
  NexBackport.define(self, :dig) do |key, *rest|
    v = self[key]
    rest.empty? || v.nil? ? v : v.dig(*rest)
  end
  NexBackport.define(self, :to_h) do |&blk|
    if blk
      h = {}
      each { |k, v| pair = blk.call(k, v); h[pair[0]] = pair[1] }
      h
    else
      self
    end
  end
  NexBackport.define(self, :transform_values) do |&blk|
    h = {}
    each { |k, v| h[k] = blk.call(v) }
    h
  end
  NexBackport.define(self, :transform_values!) do |&blk|
    keys.each { |k| self[k] = blk.call(self[k]) }
    self
  end
  NexBackport.define(self, :transform_keys) do |&blk|
    h = {}
    each { |k, v| h[blk.call(k)] = v }
    h
  end
  NexBackport.define(self, :transform_keys!) do |&blk|
    pairs = to_a
    clear
    pairs.each { |k, v| self[blk.call(k)] = v }
    self
  end
  NexBackport.define(self, :slice) do |*ks|
    h = {}
    ks.each { |k| h[k] = self[k] if has_key?(k) }
    h
  end
  NexBackport.define(self, :except) do |*ks|
    h = dup
    ks.each { |k| h.delete(k) }
    h
  end
  NexBackport.define(self, :compact) { reject { |_, v| v.nil? } }
  NexBackport.define(self, :compact!) do
    n = size
    delete_if { |_, v| v.nil? }
    n == size ? nil : self
  end
  NexBackport.define(self, :filter) { |&blk| select(&blk) }
  NexBackport.define(self, :fetch_values) { |*ks| ks.map { |k| fetch(k) } }
end

class String
  NexBackport.define(self, :delete_prefix) { |p| start_with?(p) ? self[p.length..-1] : dup }
  NexBackport.define(self, :delete_suffix) { |s| end_with?(s) && !s.empty? ? self[0, length - s.length] : dup }
  NexBackport.define(self, :casecmp?) { |o| o.is_a?(String) ? downcase == o.downcase : nil }
  NexBackport.define(self, :unpack1) { |f| unpack(f)[0] }
  NexBackport.define(self, :match?) { |re, *pos| !!(re.is_a?(Regexp) ? re : Regexp.new(Regexp.escape(re.to_s))).match(self, *pos) }
  NexBackport.define(self, :b) { dup.force_encoding('ASCII-8BIT') }
  NexBackport.define(self, :scrub) do |*rep|
    valid_encoding? ? dup : encode('UTF-16LE', :invalid => :replace, :undef => :replace, :replace => (rep[0] || '?')).encode('UTF-8')
  end
  NexBackport.define(self, :+@) { frozen? ? dup : self }
  NexBackport.define(self, :-@) { frozen? ? self : dup.freeze }
end

class Symbol
  NexBackport.define(self, :start_with?) { |*a| to_s.start_with?(*a.map { |x| x.to_s }) }
  NexBackport.define(self, :end_with?) { |*a| to_s.end_with?(*a.map { |x| x.to_s }) }
end

class Regexp
  NexBackport.define(self, :match?) { |s, *pos| s.nil? ? false : !!match(s.to_s, *pos) }
end

class Struct
  NexBackport.define(self, :to_h) do |&blk|
    h = {}
    members.each { |m| pair = blk ? blk.call(m, self[m]) : [m, self[m]]; h[pair[0]] = pair[1] }
    h
  end
end

module Comparable
  NexBackport.define(self, :clamp) do |lo, hi = nil|
    if lo.is_a?(Range)
      hi = lo.end
      lo = lo.begin
    end
    return lo if !lo.nil? && (self <=> lo) < 0
    return hi if !hi.nil? && (self <=> hi) > 0
    self
  end
end

class Numeric
  NexBackport.define(self, :positive?) { self > 0 }
  NexBackport.define(self, :negative?) { self < 0 }
end

class Integer
  NexBackport.define(self, :digits) do |*base|
    b = base[0] || 10
    n = self
    raise Math::DomainError, 'out of domain' if n < 0
    return [0] if n == 0
    out = []
    while n > 0
      out << n % b
      n /= b
    end
    out
  end
  NexBackport.define(self, :bit_length) do
    n = self < 0 ? ~self : self
    len = 0
    while n > 0
      n >>= 1
      len += 1
    end
    len
  end
  NexBackport.define(self, :pow) { |e, *m| m.empty? ? self**e : (self**e) % m[0] }
  unless Integer.respond_to?(:sqrt)
    def Integer.sqrt(n)
      Math.sqrt(n).floor
    end
  end
end

module Kernel
  NexBackport.define(self, :itself) { self }
  NexBackport.define(self, :then) { |&blk| blk ? blk.call(self) : self }
  NexBackport.define(self, :yield_self) { |&blk| blk ? blk.call(self) : self }
  unless Kernel.private_method_defined?(:__dir__) || Kernel.method_defined?(:__dir__)
    def __dir__
      line = caller(1)[0].to_s
      file = line.sub(/:\d+(:in .*)?\z/, '')
      File.dirname(File.expand_path(file))
    end
  end
  # Refinements (`refine`/`using`) cannot be built in Ruby 1.9. The closest honest behaviour is to
  # apply the refinement to the class directly, so a mod that depends on it still works.
  unless Kernel.private_method_defined?(:using) || Kernel.method_defined?(:using)
    def using(mod)
      self
    end
  end
end

class Module
  unless method_defined?(:refine) || private_method_defined?(:refine)
    def refine(klass, &blk)
      klass.class_eval(&blk)
      klass
    end
  end
end

class Exception
  NexBackport.define(self, :full_message) do |*a|
    (message.to_s + " (" + self.class.to_s + ")\n" + (backtrace || []).join("\n"))
  end
end

class << File
  NexBackport.define(self, :binwrite) do |name, data, *rest|
    File.open(name, 'wb') { |f| f.write(data) }
    data.to_s.bytesize
  end
  NexBackport.define(self, :empty?) { |n| File.exist?(n) && File.size(n) == 0 }
end

class << Dir
  NexBackport.define(self, :children) { |d, *r| Dir.entries(d).reject { |e| e == '.' || e == '..' } }
  NexBackport.define(self, :each_child) do |d, *r, &blk|
    Dir.entries(d).reject { |e| e == '.' || e == '..' }.each(&blk)
  end
  NexBackport.define(self, :empty?) { |d| File.directory?(d) && Dir.entries(d).length <= 2 }
end

module Process
  unless const_defined?(:CLOCK_MONOTONIC)
    CLOCK_REALTIME = 0
    CLOCK_MONOTONIC = 1
    CLOCK_PROCESS_CPUTIME_ID = 2
    CLOCK_THREAD_CPUTIME_ID = 3
  end
  unless respond_to?(:clock_gettime)
    def self.clock_gettime(id = 0, unit = :float_second)
      t = Time.now.to_f
      case unit
      when :float_millisecond then t * 1000.0
      when :float_microsecond then t * 1000000.0
      when :millisecond then (t * 1000).to_i
      when :microsecond then (t * 1000000).to_i
      when :nanosecond then (t * 1000000000).to_i
      when :second then t.to_i
      else t
      end
    end
  end
end

# ---------------------------------------------------------------------------------------------
# Safety net 2: common Windows calls the core's Win32API stand-ins do not answer (they would
# return 0 and leave the game without its settings). Only added when the core has no class.
# ---------------------------------------------------------------------------------------------
module Win32API_Impl
  module NexIni
    def self.path(file)
      f = file.to_s.gsub("\\", '/')
      f = f[2..-1] if f =~ /\A[A-Za-z]:\//
      f
    end

    def self.read(file)
      data = {}
      section = nil
      f = path(file)
      return data unless File.exist?(f)
      File.read(f).split(/\r?\n/).each do |line|
        l = line.strip
        next if l.empty? || l[0, 1] == ';'
        if l =~ /\A\[(.*)\]\z/
          section = $1.downcase
          data[section] ||= {}
        elsif section && (i = l.index('='))
          data[section][l[0, i].strip.downcase] = l[(i + 1)..-1].to_s.strip
        end
      end
      data
    rescue Exception
      {}
    end

    def self.fill(buffer, size, text, wide)
      return text.length unless buffer.is_a?(String)
      size = size.to_i
      text = text[0, [size - 1, 0].max]
      bytes = wide ? text.unpack('U*').pack('v*') + "\0\0" : text.unpack('C*').pack('C*') + "\0"
      buffer.force_encoding('ASCII-8BIT')
      buffer[0, bytes.length] = bytes
      text.length
    end

    def self.write(file, section, key, value)
      f = path(file)
      sec = section.to_s
      lines = File.exist?(f) ? File.read(f).split(/\r?\n/) : []
      in_sec = false
      done = false
      out = []
      lines.each do |line|
        if line.strip =~ /\A\[(.*)\]\z/
          if in_sec && !done && key
            out << "#{key}=#{value}"
            done = true
          end
          in_sec = $1.downcase == sec.downcase
        elsif in_sec && key && !done && line.strip.downcase.index(key.to_s.downcase + '=') == 0
          line = "#{key}=#{value}"
          done = true
        end
        out << line
      end
      unless done || key.nil?
        out << "[#{sec}]" unless in_sec
        out << "#{key}=#{value}"
      end
      File.open(f, 'wb') { |io| io.write(out.join("\r\n") + "\r\n") }
      1
    rescue Exception
      0
    end
  end

  module Kernel32
    unless const_defined?(:GetPrivateProfileStringA)
      class GetPrivateProfileStringA
        def wide; false; end
        def call(a)
          sec = NexIni.read(a[5])[a[0].to_s.downcase]
          val = sec && a[1].is_a?(String) ? sec[a[1].downcase] : nil
          val = a[2].to_s if val.nil?
          NexIni.fill(a[3], a[4], val, wide)
        end
      end
      class GetPrivateProfileStringW < GetPrivateProfileStringA
        def wide; true; end
      end
    end
    unless const_defined?(:GetPrivateProfileIntA)
      class GetPrivateProfileIntA
        def call(a)
          sec = NexIni.read(a[3])[a[0].to_s.downcase]
          val = sec ? sec[a[1].to_s.downcase] : nil
          val.nil? ? a[2].to_i : val.to_i
        end
      end
      GetPrivateProfileIntW = GetPrivateProfileIntA
    end
    unless const_defined?(:WritePrivateProfileStringA)
      class WritePrivateProfileStringA
        def call(a)
          NexIni.write(a[3], a[0], a[1], a[2])
        end
      end
      WritePrivateProfileStringW = WritePrivateProfileStringA
    end
    unless const_defined?(:GetTickCount)
      class GetTickCount
        def call(a); (Time.now.to_f * 1000).to_i & 0xFFFFFFFF; end
      end
    end
    unless const_defined?(:GetUserDefaultLangID)
      class GetUserDefaultLangID
        def call(a); 0x0409; end
      end
      GetSystemDefaultLangID = GetUserDefaultLangID
      GetUserDefaultUILanguage = GetUserDefaultLangID
      GetUserDefaultLCID = GetUserDefaultLangID
    end
    unless const_defined?(:Sleep)
      class Sleep
        def call(a); sleep(a[0].to_i / 1000.0) if a[0].to_i > 0; 0; end
      end
    end
    unless const_defined?(:GetLastError)
      class GetLastError
        def call(a); 0; end
      end
      SetLastError = GetLastError
    end
    unless const_defined?(:GetCurrentProcessId)
      class GetCurrentProcessId
        def call(a); 1; end
      end
      GetModuleHandle = GetCurrentProcessId
      GetModuleHandleA = GetCurrentProcessId
      GetModuleHandleW = GetCurrentProcessId
    end
    unless const_defined?(:QueryPerformanceCounter)
      class QueryPerformanceCounter
        def call(a)
          v = (Time.now.to_f * 1000000).to_i
          a[0].replace([v].pack('Q')) if a[0].is_a?(String) && !a[0].frozen?
          1
        end
      end
      class QueryPerformanceFrequency
        def call(a)
          a[0].replace([1000000].pack('Q')) if a[0].is_a?(String) && !a[0].frozen?
          1
        end
      end
    end
  end

  module Winmm
    unless const_defined?(:TimeGetTime)
      class TimeGetTime
        def call(a); (Time.now.to_f * 1000).to_i & 0xFFFFFFFF; end
      end
    end
  end

  module User32
    unless const_defined?(:MessageBoxA)
      class MessageBoxA
        def call(a)
          DL.nex_log('MessageBox: ' + a[1].to_s) if defined?(DL)
          1
        end
      end
      MessageBoxW = MessageBoxA
    end
    unless const_defined?(:GetDesktopWindow)
      class GetDesktopWindow
        def call(a); 1; end
      end
      GetActiveWindow = GetDesktopWindow
    end
    unless const_defined?(:SetWindowTextA)
      class SetWindowTextA
        def call(a); 1; end
      end
      SetWindowTextW = SetWindowTextA
    end
  end

  module Shell32
    unless const_defined?(:ShellExecute)
      class ShellExecute
        def call(a); 33; end
      end
      ShellExecuteA = ShellExecute
      ShellExecuteW = ShellExecute
    end
  end
end

module NexKGL
  @lights = {}
  @frame = 0
  @fb = nil
  @sb = nil
  @hooked = false

  class << self
    def call(name, args)
      hook_graphics
      case name
      when 'kglVersion' then 200
      when 'kglLoad' then 1
      when 'kglClear' then clear(args[0], args[1])
      when 'kglBlank' then blank(args[0])
      when 'kglClone' then clone_bitmap(args[0], args[1])
      when 'kglBindFramebuffer' then @fb = bitmap_for(args[0]); 0
      when 'kglUnbindFramebuffer' then @fb = nil; 0
      when 'kglBindShadowbuffer' then @sb = bitmap_for(args[0]); 0
      when 'kglUnbindShadowbuffer' then @sb = nil; 0
      when 'kglLightShader' then light_shader(args[0], args[1], args[2], args[3])
      when 'kglShadowShaderH' then shadow_h(args[0], args[1], args[2])
      when 'kglShadowShaderV', 'kglShadowShaderW' then shadow_v(args[0], args[1], args[2])
      else 0
      end
    rescue StandardError, NameError => e
      DL.nex_log('KGL ' + name.to_s + ' failed: ' + e.class.to_s + ' ' + e.message.to_s[0, 100])
      0
    end

    def bitmap_for(id)
      object = ObjectSpace._id2ref(id.to_i)
      (object.is_a?(Bitmap) && !object.disposed?) ? object : nil
    rescue RangeError, StandardError
      nil
    end

    # kglClear(bitmap, colour): colour is b | g << 8 | r << 16 | a << 24.
    def clear(id, color)
      bitmap = bitmap_for(id)
      return 0 unless bitmap
      value = color.to_i & 0xFFFFFFFF
      bitmap.clear
      bitmap.fill_rect(bitmap.rect, Color.new((value >> 16) & 255, (value >> 8) & 255, value & 255, (value >> 24) & 255))
      0
    end

    def blank(id)
      bitmap = bitmap_for(id)
      bitmap.clear if bitmap
      0
    end

    def clone_bitmap(target_id, source_id)
      target = bitmap_for(target_id)
      source = bitmap_for(source_id)
      return 0 unless target && source
      target.clear
      target.blt(0, 0, source, source.rect)
      0
    end

    def shadow_opacity
      shadows = $game_map.shadows
      shadows.respond_to?(:opacity) ? shadows.opacity.to_i : 255
    rescue StandardError, NameError
      255
    end

    def light_z
      limit = 1070
      begin
        limit = System_Settings::KHAS_SHADOW_Z if defined?(System_Settings) && System_Settings.const_defined?(:KHAS_SHADOW_Z)
      rescue StandardError, NameError
      end
      limit - 1
    end

    def light_shader(id, tx, ty, opacity)
      bitmap = bitmap_for(id)
      return 0 unless bitmap
      opacity = opacity.to_i
      return 0 if opacity <= 0
      entry = @lights[id.to_i]
      if entry.nil? || entry[1] != bitmap
        sprite = Sprite.new
        sprite.bitmap = bitmap
        sprite.blend_type = 1
        sprite.z = light_z
        entry = [sprite, bitmap, @frame]
        @lights[id.to_i] = entry
        describe_light(bitmap)
      end
      sprite = entry[0]
      sprite.x = tx.to_i
      sprite.y = ty.to_i
      opacity = 255 if opacity > 255
      sprite.opacity = opacity * shadow_opacity / 255
      sprite.visible = true
      entry[2] = @frame
      0
    end

    # What the light images look like, to read in the log (first few only).
    def describe_light(bitmap)
      @described = 0 unless @described
      return if @described >= 3
      @described += 1
      centre = bitmap.get_pixel(bitmap.width / 2, bitmap.height / 2)
      corner = bitmap.get_pixel(0, 0)
      DL.nex_log('KGL light ' + bitmap.width.to_s + 'x' + bitmap.height.to_s + ' centre rgba ' +
        [centre.red.to_i, centre.green.to_i, centre.blue.to_i, centre.alpha.to_i].inspect + ' corner rgba ' +
        [corner.red.to_i, corner.green.to_i, corner.blue.to_i, corner.alpha.to_i].inspect)
    rescue StandardError, NameError
    end

    # Before each screen update: lights that were not drawn this frame are hidden, and sprites of disposed light
    # bitmaps are disposed.
    def tick
      @lights.each do |id, entry|
        sprite = entry[0]
        if entry[1].disposed?
          sprite.dispose unless sprite.disposed?
          @lights.delete(id)
        elsif entry[2] != @frame
          sprite.visible = false unless sprite.disposed?
        end
      end
      @frame += 1
    rescue StandardError, NameError
    end

    def hook_graphics
      return if @hooked
      @hooked = true
      return unless defined?(Graphics) && Graphics.respond_to?(:update) && !Graphics.respond_to?(:nex_kgl_update)
      class << Graphics
        alias_method :nex_kgl_update, :update
        def update(*args)
          ::NexKGL.tick
          nex_kgl_update(*args)
        end
      end
      DL.nex_log('KGL: the lighting library is done with sprites (light = add-blended sprite below the darkness sprite)')
    rescue StandardError, NameError
    end

    # A horizontal wall piece from x1 to x2 at row y (all relative to the light bitmap): the shadow is the part of the
    # bitmap behind it, seen from the bitmap's centre.
    def shadow_h(x1, x2, y)
      bitmap = @sb
      return 0 unless bitmap
      x1, x2 = x2, x1 if x1 > x2
      w = bitmap.width
      h = bitmap.height
      cx = w / 2.0
      cy = h / 2.0
      return 0 if y == cy
      if y > cy
        first = [y.ceil, 0].max
        last = h - 1
      else
        first = 0
        last = [y.floor - 1, h - 1].min
      end
      r = first
      while r <= last
        t = (y > cy) ? (r - cy) / (y - cy) : (cy - r) / (cy - y)
        left = (cx + (x1 - cx) * t).floor
        right = (cx + (x2 - cx) * t).ceil
        left = 0 if left < 0
        right = w if right > w
        bitmap.clear_rect(left, r, right - left, 1) if right > left
        r += 1
      end
      0
    end

    # A vertical wall piece from y1 to y2 at column x.
    def shadow_v(y1, y2, x)
      bitmap = @sb
      return 0 unless bitmap
      y1, y2 = y2, y1 if y1 > y2
      w = bitmap.width
      h = bitmap.height
      cx = w / 2.0
      cy = h / 2.0
      return 0 if x == cx
      if x > cx
        first = [x.ceil, 0].max
        last = w - 1
      else
        first = 0
        last = [x.floor - 1, w - 1].min
      end
      c = first
      while c <= last
        t = (x > cx) ? (c - cx) / (x - cx) : (cx - c) / (cx - x)
        top = (cy + (y1 - cy) * t).floor
        bottom = (cy + (y2 - cy) * t).ceil
        top = 0 if top < 0
        bottom = h if bottom > h
        bitmap.clear_rect(c, top, 1, bottom - top) if bottom > top
        c += 1
      end
      0
    end
  end
end

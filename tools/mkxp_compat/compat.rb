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
      if @dll.to_s =~ /BitmapChanger_Optimization\.dll\z/i
        return NexPalette.call(@func.to_s, args)
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

# Windows calls the core does not implement answer 0, which a game reads as "failed" (no window, no device context,
# no brush) and then skips or raises. Answer what Windows answers when the call succeeds (8.17.0). Plain Ruby 1.9.
module NexWin32
  ERROR_DEVICE_NOT_CONNECTED = 1167
  @handle = 0x10000
  @brushes = {}

  def self.handle
    @handle += 4
  end

  # Returns [true, value] when the function is known here, [false, nil] otherwise.
  def self.call(dll, func, args)
    lib = dll.to_s.downcase.sub(/\.dll\z/, '').sub(/\A.*[\/\\]/, '')
    name = func.to_s.sub(/[AW]\z/, '')
    case lib
    when 'user32'
      case name
      when 'ShowWindow', 'SetWindowLong', 'SetWindowLongPtr', 'GetWindowLong', 'SetFocus', 'SetCapture', 'ReleaseCapture' then [true, 0]
      when 'SetWindowPos', 'UpdateWindow', 'ReleaseDC', 'FillRect', 'EmptyClipboard', 'OpenClipboard', 'CloseClipboard',
           'SetKeyboardState', 'SetForegroundWindow', 'BringWindowToTop', 'MoveWindow', 'InvalidateRect', 'SetCursorPos',
           'DestroyWindow', 'SetWindowText', 'EnableWindow', 'FlashWindow', 'IsWindow', 'IsWindowVisible' then [true, 1]
      when 'CreateWindowEx', 'GetDC', 'GetWindowDC', 'GetDesktopWindow', 'GetActiveWindow', 'GetFocus' then [true, handle]
      when 'GetKeyboardLayout' then [true, 0x04090409]
      when 'GetClipboardData', 'SetClipboardData' then [true, 0]
      when 'SendInput' then [true, args[0].to_i]
      when 'GetDoubleClickTime' then [true, 500]
      when 'GetCaretBlinkTime' then [true, 530]
      when 'MessageBox' then [true, 1]
      else [false, nil]
      end
    when 'gdi32'
      case name
      when 'CreateSolidBrush', 'CreateCompatibleDC', 'CreateCompatibleBitmap', 'CreateDC', 'CreatePen', 'CreateFont' then [true, handle]
      when 'SelectObject' then [true, handle]
      when 'DeleteObject', 'DeleteDC', 'BitBlt', 'StretchBlt', 'SetBkMode', 'SetTextColor' then [true, 1]
      when 'GetDeviceCaps' then [true, (args[1].to_i == 88 || args[1].to_i == 90) ? 96 : 0]
      else [false, nil]
      end
    when 'xinput9_1_0', 'xinput1_3', 'xinput1_4', 'xinput1_2', 'xinput'
      case name
      when 'XInputGetState', 'XInputSetState', 'XInputGetCapabilities', 'XInputGetBatteryInformation', 'XInputGetKeystroke'
        [true, ERROR_DEVICE_NOT_CONNECTED]
      when 'XInputEnable' then [true, 0]
      else [false, nil]
      end
    when 'kernel32'
      case name
      when 'GetTickCount' then [true, (Graphics.frame_count * 1000 / 60) & 0x7FFFFFFF]
      when 'Sleep', 'SetLastError', 'SetErrorMode', 'SetThreadPriority' then [true, 0]
      when 'GetLastError' then [true, 0]
      when 'GetCurrentProcessId' then [true, 4242]
      when 'GetACP' then [true, 1252]
      when 'GetUserDefaultLangID', 'GetSystemDefaultLangID' then [true, 0x0409]
      else [false, nil]
      end
    when 'winmm'
      case name
      when 'timeGetTime' then [true, (Graphics.frame_count * 1000 / 60) & 0x7FFFFFFF]
      when 'timeBeginPeriod', 'timeEndPeriod' then [true, 0]
      else [false, nil]
      end
    else
      [false, nil]
    end
  rescue StandardError, NameError
    [false, nil]
  end
end
begin
  Win32API.class_eval do
    next if method_defined?(:nex_call_before_win32)
    alias_method :nex_call_before_win32, :call
    def call(*args)
      unless @mkxp_wrap_impl || @mkxp_native_available
        known, value = NexIni.call(@func, args)
        known, value = NexClipboard.call(@func, args) unless known
        known, value = NexWin32.call(@dll, @func, args) unless known
        unless @nex_win32_logged || @dll.to_s =~ /kgl2\.klib\z|BitmapChanger_Optimization\.dll\z/i
          @nex_win32_logged = true
          DL.nex_log('Win32 ' + @dll.to_s + ':' + @func.to_s + (known ? ' answered like Windows' : ' not implemented (returns 0)'))
        end
        return value if known
      end
      nex_call_before_win32(*args)
    end
  end
rescue StandardError, NameError
end

# Bitmap#get_data / set_data / get_data_ptr (LonaRPG's 230_BitmapExport.rb) read the Windows memory behind a Bitmap through
# RtlMoveMemory and Ruby's internal pointers. That cannot work here: it returned blank data, so the screenshot kept in a
# save file (Bitmap#_dump / _load), Bitmap#export and the palette changer's Ruby path all got black. Redefined with
# Bitmap#raw_data, in the format the game expects: Windows DIB = BGRA bytes, bottom row first (8.17.1). Plain Ruby 1.9.
module NexBitmapData
  @done = false

  def self.to_dib(raw, w, h)
    px = raw.unpack('N*')
    out = []
    y = h - 1
    while y >= 0
      i = y * w
      stop = i + w
      while i < stop
        v = px[i]
        out << (((v & 255) << 24) | ((v >> 24) << 16) | (((v >> 16) & 255) << 8) | ((v >> 8) & 255))
        i += 1
      end
      y -= 1
    end
    out.pack('V*')
  end

  def self.from_dib(data, w, h)
    px = data.unpack('V*')
    out = []
    y = h - 1
    while y >= 0
      i = y * w
      stop = i + w
      while i < stop
        x = px[i]
        out << ((((x >> 16) & 255) << 24) | (((x >> 8) & 255) << 16) | ((x & 255) << 8) | (x >> 24))
        i += 1
      end
      y -= 1
    end
    out.pack('N*')
  end

  def self.install
    return if @done
    return unless defined?(Bitmap) && Bitmap.method_defined?(:raw_data)
    @done = true
    Bitmap.class_eval do
      def get_data
        return ('\0' * 0) if disposed? || width < 1 || height < 1
        NexBitmapData.to_dib(raw_data, width, height)
      end
      def set_data(data)
        return 0 if disposed? || data.nil? || data.bytesize != width * height * 4
        self.raw_data = NexBitmapData.from_dib(data, width, height)
        1
      end
      def get_data_ptr
        data = get_data
        def data.free; nil; end
        return data unless block_given?
        yield data
      end
    end
    DL.nex_log('Bitmap#get_data/set_data/get_data_ptr use raw_data (save screenshots, exports and palette fallback get real pixels)')
  end
end
begin
  class << Graphics
    unless method_defined?(:nex_update_before_bitmapdata)
      alias_method :nex_update_before_bitmapdata, :update
      def update(*args)
        ::NexBitmapData.install
        nex_update_before_bitmapdata(*args)
      end
    end
  end
rescue StandardError, NameError
end

# Windows .ini files (GetPrivateProfileString / Int, WritePrivateProfileString): games keep their settings in them. The core
# answered 0 and never wrote anything, so every setting fell back to its default. Real read and write here (8.17.1).
module NexIni
  def self.path(file)
    f = file.to_s.gsub('\\', '/')
    f = f.sub(/\A\.\//, '')
    f = f.sub(/\A[A-Za-z]:/, '')
    f.empty? ? 'Game.ini' : f
  end

  def self.read(file)
    sections = {}
    order = []
    current = nil
    begin
      File.open(path(file), 'rb') do |io|
        io.each_line do |line|
          line = line.strip
          next if line.empty? || line[0, 1] == ';'
          if line =~ /\A\[(.*)\]\z/
            current = $1
            sections[current] ||= []
          elsif current && (eq = line.index('='))
            sections[current] << [line[0, eq].strip, line[eq + 1, line.length].to_s.strip]
          end
        end
      end
    rescue StandardError, SystemCallError
    end
    sections
  end

  def self.write(file, sections)
    File.open(path(file), 'wb') do |io|
      sections.each do |name, pairs|
        io.write('[' + name + "]\r\n")
        pairs.each { |k, v| io.write(k + '=' + v + "\r\n") }
        io.write("\r\n")
      end
    end
  end

  def self.find(sections, section, key)
    sec = nil
    sections.each { |n, pairs| sec = pairs if n.downcase == section.to_s.downcase }
    return nil unless sec
    pair = sec.find { |k, v| k.downcase == key.to_s.downcase }
    pair ? pair[1] : nil
  end

  def self.put(buffer, text, size)
    text = text.to_s
    limit = size.to_i > 0 ? size.to_i - 1 : text.length
    text = text[0, limit]
    if buffer.is_a?(String)
      buffer[0, text.length + 1] = text + "\0"
    end
    text.length
  end

  # Returns [known, value].
  def self.call(func, args)
    case func.to_s.sub(/[AW]\z/, '')
    when 'GetPrivateProfileString'
      # section, key, default, buffer, size, file
      value = find(read(args[5]), args[0], args[1])
      [true, put(args[3], value.nil? ? args[2] : value, args[4])]
    when 'GetPrivateProfileInt'
      value = find(read(args[3]), args[0], args[1])
      [true, (value.nil? ? args[2].to_i : value.to_i)]
    when 'WritePrivateProfileString'
      # section, key, value, file
      sections = read(args[3])
      name = sections.keys.find { |n| n.downcase == args[0].to_s.downcase } || args[0].to_s
      sections[name] ||= []
      if args[1].nil? || args[1] == 0
        sections.delete(name)
      elsif args[2].nil? || args[2] == 0
        sections[name].delete_if { |k, v| k.downcase == args[1].to_s.downcase }
      else
        pair = sections[name].find { |k, v| k.downcase == args[1].to_s.downcase }
        if pair
          pair[1] = args[2].to_s
        else
          sections[name] << [args[1].to_s, args[2].to_s]
        end
      end
      write(args[3], sections)
      [true, 1]
    else
      [false, nil]
    end
  rescue StandardError, SystemCallError, NameError
    [true, 0]
  end
end

# A clipboard and global memory that live in the game: GlobalAlloc / GlobalLock / lstrcpy / lstrlen / SetClipboardData /
# GetClipboardData, enough for copy and paste of text between a game's own fields. The handle is also the "pointer".
module NexClipboard
  @memory = {}
  @next = 0x00A00000
  @data = nil

  def self.call(func, args)
    case func.to_s.sub(/[AW]\z/, '')
    when 'GlobalAlloc'
      @next += 0x1000
      @memory[@next] = "\0" * [args[1].to_i, 1].max
      [true, @next]
    when 'GlobalLock' then [true, args[0].to_i]
    when 'GlobalUnlock' then [true, 1]
    when 'GlobalFree'
      @memory.delete(args[0].to_i)
      [true, 0]
    when 'GlobalSize' then [true, (@memory[args[0].to_i] || '').length]
    when 'lstrcpy', 'lstrcpyn'
      source = args[1].is_a?(String) ? args[1] : (@memory[args[1].to_i] || '')
      source = source.split("\0")[0].to_s
      if args[0].is_a?(String)
        args[0][0, source.length + 1] = source + "\0"
      elsif @memory[args[0].to_i]
        @memory[args[0].to_i] = source + "\0"
      else
        return [true, 0]
      end
      [true, args[0].is_a?(String) ? 1 : args[0].to_i]
    when 'lstrlen'
      text = args[0].is_a?(String) ? args[0] : (@memory[args[0].to_i] || '')
      [true, text.split("\0")[0].to_s.length]
    when 'SetClipboardData'
      @data = (@memory[args[1].to_i] || '').dup
      [true, args[1].to_i]
    when 'GetClipboardData'
      return [true, 0] if @data.nil?
      @next += 0x1000
      @memory[@next] = @data.dup
      [true, @next]
    when 'EmptyClipboard'
      @data = nil
      [true, 1]
    else
      [false, nil]
    end
  rescue StandardError, NameError
    [true, 0]
  end
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

  # The core's windows_fs.rb gives File its own read/readlines/foreach (they call the C originals directly, so the
  # IO.read patch below is bypassed for File.read) and its universal-newline help only works on Ruby >= 3.1.
  # Clean the results of the bare forms (File.read(path), File.readlines(path), File.foreach(path)) here too.
  [IO, File].each do |nex_k|
    begin
      next if nex_k.singleton_class.method_defined?(:nex_whole_read_before)
      nex_k.singleton_class.class_eval do
        alias_method :nex_whole_read_before, :read
        alias_method :nex_whole_readlines_before, :readlines
        alias_method :nex_whole_foreach_before, :foreach
        def read(*args)
          text = nex_whole_read_before(*args)
          args.length == 1 ? NexTextMode.clean(text) : text
        end
        def readlines(*args)
          lines = nex_whole_readlines_before(*args)
          args.length == 1 ? lines.map { |l| NexTextMode.clean(l) } : lines
        end
        def foreach(*args, &block)
          return nex_whole_foreach_before(*args) unless block && args.length == 1
          nex_whole_foreach_before(*args) { |l| block.call(NexTextMode.clean(l)) }
        end
        if respond_to?(:ruby2_keywords, true)
          ruby2_keywords :read
          ruby2_keywords :readlines
          ruby2_keywords :foreach
        end
      end
    rescue Exception => e
      DL.nex_log('text clean for ' + nex_k.to_s + ' failed: ' + e.message)
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

# Directory listing order (8.16.9). Windows (NTFS) returns Dir[] / Dir.glob results alphabetically (case-insensitive);
# iOS returns them in file-system order (arbitrary). LonaRPG loads its scripts by sorting Dir[] results on the number in
# front of the file name (`to_i`), so files without a number all tie and keep the order Dir[] gave them: with the
# arbitrary order Sensors_Battle.rb could load before Sensors.rb, `Battle_Sensor < Basic_Sensor` then inherited from the
# core's IOS::NullStub, and every attack's `scan` went to NullStub.method_missing (nothing was ever hit).
# Dir[] and Dir.glob now sort their results like Windows. Dir.entries/foreach are left alone (windows_fs uses them a lot).
begin
  module NexDirOrder
    def self.sort(list)
      return list unless list.is_a?(Array)
      list.sort do |a, b|
        c = a.to_s.upcase <=> b.to_s.upcase
        c == 0 ? (a.to_s <=> b.to_s) : c
      end
    end
  end
  class << Dir
    unless method_defined?(:nex_glob_orig)
      alias_method :nex_glob_orig, :glob
      alias_method :nex_aref_orig, :[]
      def glob(pattern, *rest, &block)
        list = []
        if pattern.is_a?(Array)
          pattern.each { |pt| list.concat(NexDirOrder.sort(nex_glob_orig(pt, *rest))) }
        else
          list = NexDirOrder.sort(nex_glob_orig(pattern, *rest))
        end
        if block
          list.each { |item| block.call(item) }
          return nil
        end
        list
      end
      def [](*patterns)
        list = []
        patterns.each { |pt| list.concat(NexDirOrder.sort(nex_aref_orig(pt))) }
        list
      end
      # Ruby 2.7+ (only the headless test runs on it): keep keyword arguments such as base: working.
      if respond_to?(:ruby2_keywords, true)
        ruby2_keywords(:glob)
        ruby2_keywords(:[])
      end
    end
  end
  DL.nex_log('Dir[] and Dir.glob return files in Windows order (alphabetical)')
rescue Exception => e
  DL.nex_log('Dir order guard failed: ' + e.message.to_s)
end

# Diagnostic (8.16.3): logs the skill pipeline (launch -> wait -> result) of the first skills, for every actor class
# (player and enemies): "HIT skill ...". Installed from the first Graphics.update ticks once the game's classes exist.
module NexSkillLog
  @done = false
  @lines = 0
  def self.say(text)
    return if @lines >= 6000
    @lines += 1
    DL.nex_log('HIT ' + text)
  end

  def self.describe(skill)
    return 'nil' if skill.nil?
    d = []
    [:hit_frame, :wait_hit_frame, :hitbox?, :is_projectile?, :blocking?, :holding?, :chs_animation].each do |m|
      begin
        d << m.to_s + '=' + skill.send(m).inspect if skill.respond_to?(m)
      rescue Exception => e
        d << m.to_s + '=ERR'
      end
    end
    det = (skill.hit_detection.name rescue '?')
    d << 'detection=' + det.to_s
    d.join(' ')
  end

  # Bounded trace: after the first skill launch, records up to 400 Ruby method calls whose name looks combat related
  # (skill/hit/damage/scan/sensor/target/attack/effect/aggro/dodge/block) for at most 240 frames, then writes them.
  # 8.16.10: the per-attack call trace made fights drop to 43-47 fps; the cause (Dir order) is fixed, so it is off.
  # Set to true to trace the first 10 attacks again.
  TRACE_ON = false
  TRACE_RE = /skill|hit|damage|scan|sensor|sense|attack|aggro|block|popup|result|dodge|cancel/i
  TRACE_SKIP = /\Anex_|\Asay\z|\Adescribe\z|\Aentered\z|\Areport\z|\Ainstall\z|\Astart_trace|\Afinish_trace|\Aupdate_(dodge|aggro_frame|npc_sensor|target|skill_input)|ex_effects|new_effect|sensor_stop|is_skill|roster_input|chk_skill_eff|char_block|\Aupdate_popups|damage_effect|charge_effects|slime/i
  # One trace per attack (the first 3 attacks of any actor, enemies included): from the moment process_skill_result
  # starts until it returns, so only the target check / damage chain is recorded.
  def self.start_trace(label)
    return if @tracing || @traces_done.to_i >= 10
    @tracing = true
    @trace_label = label
    @trace = []
    begin
      set_trace_func(proc do |event, file, line, id, bind, klass|
        if @trace.size < 4000
          where = file.to_s.split('/').last.to_s + ':' + line.to_s
          if event == 'raise'
            ex = $!
            info = ex ? (ex.class.to_s + ': ' + ex.message.to_s[0, 160]) : 'raise ?'
            @trace << ('RAISE ' + info + ' @' + where)
          elsif event == 'call' && id == :method_missing
            info = (eval("(self.is_a?(Module) ? self.name.to_s : self.class.to_s) + ' ' + local_variables.map { |v| v.to_s + '=' + (eval(v.to_s).inspect[0, 60] rescue '?') }.join(' ')", bind) rescue 'n/a')
            @trace << ('method_missing{' + info + '} @' + where)
          elsif event == 'call' && id && id.to_s !~ TRACE_SKIP
            @trace << (klass.to_s + '#' + id.to_s)
          end
        end
      end)
    rescue Exception => e
      say('trace failed: ' + e.message.to_s)
      @tracing = false
    end
  end

  def self.finish_trace
    return unless @tracing
    @tracing = false
    @traces_done = @traces_done.to_i + 1
    begin
      set_trace_func(nil)
    rescue Exception
    end
    counts = {}
    order = []
    @trace.each do |name|
      order << name unless counts[name]
      counts[name] = (counts[name] || 0) + 1
    end
    DL.nex_log('HIT trace of ' + @trace_label.to_s + ': ' + @trace.size.to_s + ' calls, ' + order.size.to_s + ' different')
    order.each_slice(5) do |group|
      DL.nex_log('HIT calls: ' + group.map { |n| n + ' x' + counts[n].to_s }.join(', '))
    end
  end

  def self.trace_tick
  end

  def self.install
    trace_tick
    return if @done
    return unless defined?(Game_Actor) && defined?(Game_Player)
    @done = true
    [Game_Actor, (defined?(Game_NonPlayerCharacter) ? Game_NonPlayerCharacter : nil)].compact.each do |klass|
      [:launch_effect_skill, :process_skill_result].each do |meth|
        next unless klass.method_defined?(meth) || klass.private_method_defined?(meth)
        orig = 'nex_orig_' + meth.to_s
        next if klass.method_defined?(orig)
        klass.class_eval do
          alias_method orig, meth
          define_method(meth) do |*args|
            begin
              NexSkillLog.say(self.class.to_s + '#' + meth.to_s + ' ' + NexSkillLog.describe(args[0]) +
                              ' state=' + (@action_state.inspect) + ' skill_wait=' + @skill_wait.inspect +
                              ' launched=' + @current_skill_launched.inspect)
            rescue Exception
            end
            traced = (meth == :process_skill_result) && NexSkillLog::TRACE_ON
            NexSkillLog.start_trace(self.class.to_s) if traced
            begin
              send(orig, *args)
            ensure
              NexSkillLog.finish_trace if traced
            end
          end
        end
      end
    end
    anc = (defined?(Sensors) && Sensors.const_defined?(:BasicAttack) ? Sensors::BasicAttack.ancestors.first(5).map { |a| a.to_s }.join(' < ') : 'no BasicAttack')
    say('skill pipeline hooks installed; BasicAttack ancestors: ' + anc)
  rescue Exception => e
    DL.nex_log('HIT skill hook failed: ' + e.class.to_s + ' ' + e.message.to_s)
  end
end


# Diagnostic (8.16.2): LonaRPG decides who an attack hits in Sensors::*.scan (plain Ruby geometry on a detection array).
# When attacks "play but hit nothing" this logs, for the first attacks of the player, WHY each nearby target was
# rejected: ignored (dead/object/friend/self), outside the detection area (mine value nil/0), or blocked by terrain.
# Lines: "[NexPlay compat] HIT ...". Capped at 60 lines per run. Plain Ruby 1.9 syntax only.
module NexHitLog
  @lines = 0
  def self.say(text)
    return if @lines >= 600
    @lines += 1
    DL.nex_log('HIT ' + text)
  end

  def self.entered(sensor, args)
    @entered = (@entered || 0) + 1
    say('scan #' + @entered.to_s + ' called on ' + sensor.name.to_s + ' by ' + args[0].class.to_s) if @entered <= 6
  rescue Exception
  end

  def self.report(sensor, args, result)
    return if @lines >= 600
    character = args[0]
    targets = args[1] || $game_map.all_characters
    near = []
    targets.each do |tgt|
      begin
        next if tgt.equal?(character)
        dx = (tgt.x - character.x).abs
        dy = (tgt.y - character.y).abs
        near << tgt if dx <= 5 && dy <= 8
      rescue Exception
      end
    end
    say('scan ' + sensor.name.to_s + (defined?($game_player) && character.equal?($game_player) ? ' (player)' : ' (' + character.class.to_s + ')') + ': ' + targets.size.to_s + ' characters, ' + near.size.to_s + ' near, ' +
        result.size.to_s + ' hit, player at ' + character.x.to_s + ',' + character.y.to_s + ' dir ' + character.direction.to_s +
        ' real ' + character.real_x.to_s + ',' + character.real_y.to_s)
    near.each do |tgt|
      why = nil
      begin
        if tgt.erased || tgt.deleted?
          why = 'erased/deleted'
        elsif sensor.signal_IgnoreCheck(character, tgt, false)
          why = 'ignored (not actor=' + sensor.not_actor?(tgt).inspect + ' object=' + sensor.ignore_obj_chk(character, tgt).inspect + ')'
        else
          mine = sensor.mine_number(character, tgt, false)
          xy = sensor.get_mine_xy(character, tgt, false)
          if mine.nil? || mine == 0
            why = 'outside the area: mine=' + mine.inspect + ' at ' + xy.inspect + ' of ' + sensor.area_dimension.inspect
          else
            vis = sensor.calc_sight_hp_and_dist(character, tgt)
            why = vis[0] < 0 ? ('blocked by terrain, sight ' + vis.inspect) : ('counted: mine=' + mine.to_s + ' sight ' + vis.inspect)
          end
        end
      rescue Exception => e
        why = 'ERROR ' + e.class.to_s + ': ' + e.message.to_s
      end
      say('  target at ' + tgt.x.to_s + ',' + tgt.y.to_s + ' real ' + tgt.real_x.to_s + ',' + tgt.real_y.to_s + ' -> ' + why)
    end
  end
end

# Belt and braces for the "\r" problem: whichever way a game's file reached its JSON text, the game's own JSON.decode
# (a hand-written parser that only skips " ", "\n", "\t") loops until the stack is exhausted when a "\r" is left in. The
# moment a module called JSON gets a singleton `decode`, it is wrapped so Windows line endings are folded to "\n".
begin
  module Kernel
    def singleton_method_added(name)
      # Fullscreen++ (Zeus81, many VX/VX Ace games): a saved "Fullscreen=1" in the game's ini makes the game build a
      # desktop fullscreen (borderless topmost window, back window, resize) and the player stops answering touches.
      # The core's window already fills the phone, so the fullscreen request becomes the windowed mode.
      if name == :fullscreen_mode && self.is_a?(Module) && !defined?(@nex_fullscreen_wrapped) && self.name.to_s == 'Graphics'
        @nex_fullscreen_wrapped = true
        class << self
          alias_method :nex_fullscreen_mode_orig, :fullscreen_mode
          def fullscreen_mode(*args)
            if respond_to?(:windowed_mode, true)
              unless defined?(@nex_fullscreen_logged)
                @nex_fullscreen_logged = true
                DL.nex_log('Fullscreen++ asked for fullscreen: using the windowed mode instead (the screen is already full)')
              end
              return send(:windowed_mode)
            end
            nex_fullscreen_mode_orig(*args)
          end
        end
      end
      if name == :scan && self.is_a?(Module) && !defined?(@nex_scan_wrapped) && self.name.to_s =~ /\ASensors::/
        @nex_scan_wrapped = true
        DL.nex_log('HIT hook: wrapped ' + self.name.to_s + '.scan')
        class << self
          alias_method :nex_scan_orig, :scan
          def scan(*args)
            NexHitLog.entered(self, args)
            begin
              result = nex_scan_orig(*args)
            rescue Exception => e
              NexHitLog.say('scan RAISED ' + e.class.to_s + ': ' + e.message.to_s + ' at ' + (e.backtrace || [])[0, 4].join(' | '))
              raise
            end
            begin
              NexHitLog.report(self, args, result)
            rescue Exception => e
              NexHitLog.say('report failed ' + e.class.to_s + ': ' + e.message.to_s + ' at ' + (e.backtrace || [])[0, 3].join(' | '))
            end
            result
          end
        end
      end
      if name == :decode && self.is_a?(Module) && !defined?(@nex_json_wrapped) && self.name.to_s == 'JSON'
        @nex_json_wrapped = true
        class << self
          alias_method :nex_decode_before_cr, :decode
          def decode(json, *rest)
            if json.is_a?(String)
              begin
                json = json.gsub("\r\n", "\n").gsub("\r", "\n") if json.index("\r")
              rescue Exception
              end
            end
            nex_decode_before_cr(json, *rest)
          end
        end
        DL.nex_log('JSON.decode folds Windows line endings')
      end
    end
    private :singleton_method_added
  end
rescue Exception => e
  DL.nex_log('JSON line-ending guard failed: ' + e.message)
end

# One log line that says whether text-mode reading works in this core (read it first if a "\r" problem comes back).
begin
  nex_dir = ENV['TMPDIR'] || '/tmp'
  nex_probe = File.join(nex_dir, 'nexplay_crlf_probe.txt')
  File.open(nex_probe, 'wb') { |f| f.write("a\r\nb") }
  nex_a = (File.open(nex_probe).read rescue 'ERR')
  nex_b = (File.read(nex_probe) rescue 'ERR')
  nex_c = (File.open(nex_probe, 'r').read rescue 'ERR')
  nex_d = (open(nex_probe).read rescue 'ERR')
  DL.nex_log('text-mode probe (open.read, File.read, open(r).read, Kernel#open.read): ' +
             [nex_a, nex_b, nex_c, nex_d].map { |x| x.inspect }.join(' '))
  File.delete(nex_probe) rescue nil
rescue Exception => e
  DL.nex_log('text-mode probe failed: ' + e.message)
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

# Palette changer (8.16.11): LonaRPG recolours bitmaps (skin / hair / clothes variants) with the Windows DLL
# Data/PaletteChanger/BitmapChanger_Optimization.dll, called through Win32API. The core's stand-in only logged those calls
# and returned 0, so no colour was ever swapped (the game believed the DLL worked, so its own Ruby fallback never ran).
# Emulated here with Bitmap#raw_data (RGBA bytes). Semantics, read from 5000_LonaBitmapChanger.rb and its Ruby fallback:
#   add_setting -> new setting number; add_swap(s, r, g, b, nr, ng, nb) / remove_swap(s, r, g, b);
#   merge_settings(a, b) adds b's colours to a and returns a; exclusive_merge(a, b) the same for colours a lacks;
#   remove_setting(s); clear_settings; remove_intersecting_settings(a, b) drops from a the colours b has;
#   process_bitmap(bitmap.__id__, w, h, s) swaps pixels whose RGB equals a colour of s (alpha kept);
#   process_bitmap_limited(..., s, x, y, w, h) only inside the rectangle;
#   schedule_mode(bitmap id, w, h) ... execute: the process_* calls in between are collected and applied in one pass,
#   every colour compared with the ORIGINAL pixel, later settings win (like the Ruby fallback's execute_filters).
# Plain Ruby 1.9 syntax only.
module NexPalette
  @settings = {}
  @next_id = 1
  @sched = nil
  @logged = false

  def self.call(func, args)
    unless @logged
      @logged = true
      DL.nex_log('BitmapChanger_Optimization.dll is done in Ruby (palette swaps are applied)')
    end
    case func
    when 'add_setting'
      id = @next_id
      @next_id += 1
      @settings[id] = {}
      id
    when 'add_swap'
      table = table_for(args[0])
      table[rgb(args[1], args[2], args[3])] = rgb(args[4], args[5], args[6])
      0
    when 'remove_swap'
      table_for(args[0]).delete(rgb(args[1], args[2], args[3]))
      0
    when 'merge_settings'
      table_for(args[0]).merge!(table_for(args[1]))
      args[0].to_i
    when 'exclusive_merge'
      target = table_for(args[0])
      table_for(args[1]).each { |k, v| target[k] = v unless target.has_key?(k) }
      args[0].to_i
    when 'remove_setting'
      @settings.delete(args[0].to_i)
      0
    when 'clear_settings'
      @settings.clear
      0
    when 'remove_intersecting_settings'
      other = table_for(args[1])
      table_for(args[0]).delete_if { |k, v| other.has_key?(k) }
      0
    when 'schedule_mode'
      @sched = { :id => args[0].to_i, :passes => [] }
      0
    when 'process_bitmap'
      queue_or_apply(args[0], args[3], nil)
      0
    when 'process_bitmap_limited'
      queue_or_apply(args[0], args[3], [args[4].to_i, args[5].to_i, args[6].to_i, args[7].to_i])
      0
    when 'execute'
      sched = @sched
      @sched = nil
      apply(sched[:id], sched[:passes]) if sched && !sched[:passes].empty?
      0
    else
      0
    end
  rescue StandardError, NameError => e
    DL.nex_log('palette ' + func.to_s + ' failed: ' + e.class.to_s + ' ' + e.message.to_s[0, 120])
    0
  end

  def self.table_for(id)
    @settings[id.to_i] ||= {}
  end

  def self.rgb(r, g, b)
    ((r.to_i & 255) << 16) | ((g.to_i & 255) << 8) | (b.to_i & 255)
  end

  def self.queue_or_apply(bitmap_id, setting, rect)
    pass = [table_for(setting), rect]
    if @sched && @sched[:id] == bitmap_id.to_i
      @sched[:passes] << pass
    else
      apply(bitmap_id.to_i, [pass])
    end
  end

  def self.apply(bitmap_id, passes)
    bitmap = (ObjectSpace._id2ref(bitmap_id) rescue nil)
    return unless bitmap.is_a?(Bitmap) && !bitmap.disposed?
    passes = passes.select { |pass| !pass[0].empty? }
    return if passes.empty?
    width = bitmap.width
    height = bitmap.height
    original = bitmap.raw_data.unpack('N*')
    result = original.dup
    changed = false
    passes.each do |pass|
      table = pass[0]
      rect = pass[1]
      if rect
        x0 = [rect[0], 0].max
        y0 = [rect[1], 0].max
        x1 = [rect[0] + rect[2], width].min
        y1 = [rect[1] + rect[3], height].min
        y = y0
        while y < y1
          i = y * width + x0
          stop = y * width + x1
          while i < stop
            value = original[i]
            swap = table[value >> 8]
            if swap
              result[i] = (swap << 8) | (value & 255)
              changed = true
            end
            i += 1
          end
          y += 1
        end
      else
        i = 0
        count = original.length
        while i < count
          value = original[i]
          swap = table[value >> 8]
          if swap
            result[i] = (swap << 8) | (value & 255)
            changed = true
          end
          i += 1
        end
      end
    end
    bitmap.raw_data = result.pack('N*') if changed
  end
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
          ::NexSkillLog.install
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

# NexPlay diagnostic: finds what recurses when a game ends with "SystemStackError: stack level too deep".
# Ruby cuts the backtrace of that error to one frame, so nothing says which methods call each other. This keeps the
# last method calls in a ring buffer and, when the call depth passes a limit, writes them to the debug log once
# (mkxp-session.log in Export Logs). It slows the game down a lot, so NexPlay only turns it on for a game after
# that game has ended with a stack error. Plain Ruby 1.8/1.9 syntax.
unless defined?(NexDeepTrace)
  module NexDeepTrace
    LIMIT = 3000
    KEEP = 60
    @depth = 0
    @ring = []
    @busy = false
    @done = false

    class << self
      def event(kind, file, line, id, klass)
        return if @busy || @done
        @busy = true
        if kind == 'call' || kind == 'c-call'
          @depth += 1
          @ring << (klass.to_s + '#' + id.to_s + ' ' + file.to_s + ':' + line.to_s + ' d' + @depth.to_s)
          @ring.shift if @ring.size > KEEP
          dump if @depth >= LIMIT
        elsif (kind == 'return' || kind == 'c-return') && @depth > 0
          @depth -= 1
        end
        @busy = false
      end

      def dump
        @done = true
        begin
          System.puts('[NexPlay trace] call depth reached ' + @depth.to_s + '; the last calls were:')
          @ring.each { |entry| System.puts('[NexPlay trace]   ' + entry) }
        rescue StandardError, NameError
        end
        extras
        set_trace_func(nil)
      end

      # A game's own JSON reader (class methods keeping @json / @index, like the common "JSON Encoder/Decoder" script)
      # is the usual deep recursion: say what it is reading and how far it got.
      def extras
        return unless defined?(::JSON)
        json = ::JSON.instance_variable_get(:@json)
        index = ::JSON.instance_variable_get(:@index)
        return unless json.respond_to?(:length)
        System.puts('[NexPlay trace] JSON text length ' + json.length.to_s + ', index ' + index.to_s)
        System.puts('[NexPlay trace] JSON text start: ' + json[0, 300].to_s.inspect)
        from = index.to_i - 150
        from = 0 if from < 0
        System.puts('[NexPlay trace] JSON text around the index: ' + json[from, 300].to_s.inspect)
        begin
          System.puts('[NexPlay trace] JSON.parse is defined at ' + ::JSON.method(:parse).source_location.inspect)
        rescue StandardError, NameError
        end
      rescue StandardError, NameError
      end
    end
  end

  set_trace_func(proc { |kind, file, line, id, binding, klass| NexDeepTrace.event(kind, file, line, id, klass) })
  begin
    System.puts('[NexPlay trace] call-depth trace is on for this run')
  rescue StandardError, NameError
  end
end

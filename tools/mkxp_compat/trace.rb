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
        set_trace_func(nil)
      end
    end
  end

  set_trace_func(proc { |kind, file, line, id, binding, klass| NexDeepTrace.event(kind, file, line, id, klass) })
  begin
    System.puts('[NexPlay trace] call-depth trace is on for this run')
  rescue StandardError, NameError
  end
end

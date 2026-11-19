// Ruby stand-ins that NexPlay hands to the mkxp core as a preload script (config "preloadScript").
// 8.13.9: LonaRPG's keyboard script (Hime/Cidiomar "Full Input") calls DL.malloc(256), wraps it in DL::CPtr and passes
// the address to Win32API GetKeyboardState. The core has no DL, so the script died and the game ended in a
// SystemStackError. The core's own GetKeyboardState stand-in writes into a buffer object, so it is taught addresses.
// Plain Ruby 1.8/1.9 syntax on purpose (the core runs the game's Ruby version).

#if NEXPLAY_MKXP
import Foundation

enum MkxpCompat {
    static let source = """
    # NexPlay stand-ins: DL.malloc / DL::CPtr as plain byte arrays, GetKeyboardState that fills them.
    module DL
      @nex_mem = {}
      @nex_next = 0x100000
      class << self
        unless respond_to?(:malloc)
          def malloc(size)
            size = size.to_i
            @nex_next += ((size + 15) / 16) * 16 + 16
            @nex_mem[@nex_next] = Array.new(size, 0)
            @nex_next
          end
        end
        unless respond_to?(:free)
          def free(addr)
            @nex_mem.delete(addr.to_i)
            0
          end
        end
        def nex_buffer(addr)
          @nex_mem[addr.to_i]
        end
      end
      unless const_defined?(:CPtr)
        class CPtr
          def initialize(addr = 0, size = 0, free = nil)
            @addr = addr.to_i
            @size = size.to_i
          end
          def to_i; @addr; end
          def to_int; @addr; end
          def size; @size; end
          def [](index, len = nil)
            buf = DL.nex_buffer(@addr) || []
            return buf[index] || 0 if len.nil?
            (buf[index, len] || []).pack('C*')
          end
          def []=(index, value)
            buf = DL.nex_buffer(@addr)
            buf[index] = value.to_i if buf
            value
          end
          def free; DL.free(@addr); end
        end
      end
    end
    begin
      Win32API_Impl::User32::GetKeyboardState.class_eval do
        alias_method :nex_original_call, :call
        def call(args)
          out = args[0]
          buf = out.is_a?(Integer) ? DL.nex_buffer(out) : nil
          return nex_original_call(args) unless buf
          Scancodes::WIN32.each do |_name, val|
            buf[val] = Input.asyncKeyState(val) > 0 ? 0x80 : 0
          end
          1
        end
      end
    rescue StandardError, NameError
    end
    """

    /// Writes the script and returns its path for mkxp.json's "preloadScript".
    static func installedPath() -> String? {
        let url = Paths.support.appendingPathComponent("mkxp-compat.rb")
        do {
            try FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
            if (try? String(contentsOf: url, encoding: .utf8)) != source {
                try source.write(to: url, atomically: true, encoding: .utf8)
            }
            return url.path
        } catch {
            AppLog.log("mkxp compat: could not write the stand-in script (\(error.localizedDescription))")
            return nil
        }
    }
}
#endif

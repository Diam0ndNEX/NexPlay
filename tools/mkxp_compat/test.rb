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
    d = 'Nolib' unless d =~ /\A[A-Z]\w*\z/   # a path such as System/KGL2.klib is no constant name (the core tolerates it)
    @impl = Win32API_Impl.const_defined?(d) && Win32API_Impl.const_get(d).const_defined?(func) ? Win32API_Impl.const_get(d).const_get(func).new : nil
  end
  def call(*args)
    return @impl.call(args) if @impl
    System.puts("[Win32API] [#{@dll}:#{@func}] #{args}")
    0
  end
end
module DL; end
class Sprite
  def visible=(value); raise TypeError, 'Argument 0: Expected bool' unless value == true || value == false || value.nil?; @visible = value; end
  def visible; @visible; end
end
Encoding.default_external = Encoding::ASCII_8BIT
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
check 'gets drops \\r', File.open(tmp).gets == "[\n"
check 'readlines drops \\r', File.open(tmp).readlines == ["[\n", "1,\n", "2\n", "]"]
check 'clean() removes \\r\\n', NexTextMode.clean("a\r\nb") == "a\nb" && NexTextMode.clean(nil).nil?
check 'File.readlines drops \\r', File.readlines(tmp) == ["[\n", "1,\n", "2\n", "]"]
check 'File.foreach drops \\r', (a = []; File.foreach(tmp) { |l| a << l }; a == ["[\n", "1,\n", "2\n", "]"])
check 'File.open "rb" keeps \\r', File.open(tmp, 'rb').read == "[\r\n1,\r\n2\r\n]"
check 'File.binread keeps \\r', File.binread(tmp) == "[\r\n1,\r\n2\r\n]"
check 'readlines drops \\r', File.open(tmp).readlines.first == "[\n"
File.open(tmp, 'wb') { |f| f.write(Marshal.dump([1, "a\r\nb"])) }
check 'Marshal through "rb" is intact', Marshal.load(File.open(tmp, 'rb')) == [1, "a\r\nb"]
File.open(tmp, 'w') { |f| f.write("x\ny") }
check 'writing still works', File.read(tmp) == "x\ny"
check 'File.read with an options hash works', File.read(tmp, :encoding => 'UTF-8') == "x\ny"
File.open(tmp, 'wb') { |f| f.write("a\r\nb") }
check 'File.read with options drops \\r', File.read(tmp, :encoding => 'UTF-8') == "a\nb"
check 'File.open with options drops \\r', File.open(tmp, 'r', :encoding => 'UTF-8').read == "a\nb"
check 'File.read with a length still works', File.read(tmp, 2).length == 2
File.delete(tmp)
sprite = Sprite.new
sprite.visible = Object.new
check 'visible= takes any object', sprite.visible == true
sprite.visible = 0
check 'visible= takes 0 as on (as RGSS)', sprite.visible == true
sprite.visible = nil
check 'visible= takes nil as off', sprite.visible == false
check 'binary default encoding raised to UTF-8', Encoding.default_external == Encoding::UTF_8
load File.join(File.dirname(__FILE__), 'compat.rb')
sprite.visible = 5
check 'second load keeps the wrapper working', sprite.visible == true

# Khas Graphics Library done with sprites.
class Rect; attr_reader :x, :y, :width, :height; def initialize(x, y, w, h); @x, @y, @width, @height = x, y, w, h; end; end
class Color
  attr_reader :red, :green, :blue, :alpha
  def initialize(r = 0, g = 0, b = 0, a = 255); @red, @green, @blue, @alpha = r, g, b, a; end
end
class Bitmap
  attr_reader :width, :height, :log
  def initialize(w, h); @width = w; @height = h; @log = []; @disposed = false; end
  def rect; Rect.new(0, 0, @width, @height); end
  def clear; @log << [:clear]; end
  def fill_rect(r, c); @log << [:fill, c.red, c.green, c.blue, c.alpha]; end
  def clear_rect(x, y, w, h); @log << [:clear_rect, x, y, w, h]; end
  def blt(x, y, src, r); @log << [:blt, x, y, src.object_id]; end
  def get_pixel(x, y); Color.new(255, 240, 200, 128); end
  def dispose; @disposed = true; end
  def disposed?; @disposed; end
end
class Sprite
  attr_accessor :bitmap, :blend_type, :x, :y, :z, :opacity
  def dispose; @gone = true; end
  def disposed?; @gone ? true : false; end
end
module Graphics
  @updates = 0
  def self.update; @updates += 1; end
  def self.updates; @updates; end
end
class ShadowsMock; def opacity; 128; end; end
class MapMock; def shadows; ShadowsMock.new; end; end
$game_map = MapMock.new
def kgl(name, *args); Win32API.new('System/KGL2.klib', name, '', 'i').call(*args); end

framebuffer = Bitmap.new(544, 416)
kgl('kglClear', framebuffer.__id__, 30 | (60 << 8) | (90 << 16) | (255 << 24))
check 'kglClear fills the ambient colour (r g b a)', framebuffer.log == [[:clear], [:fill, 90, 60, 30, 255]]
check 'kglVersion is 2.0', kgl('kglVersion') == 200

light = Bitmap.new(100, 100)
kgl('kglLightShader', light.__id__, 10, 20, 255)
sprites = ObjectSpace.each_object(Sprite).select { |sp| sp.bitmap.equal?(light) }
check 'a light becomes one add-blended sprite', sprites.length == 1 && sprites[0].blend_type == 1
check 'light sprite position', sprites[0].x == 10 && sprites[0].y == 20
check 'light sprite strength follows the darkness opacity', sprites[0].opacity == 128
check 'light sprite sits just below the darkness sprite', sprites[0].z == 1069
check 'light image format is logged', $out.any? { |m| m.include?('KGL light 100x100 centre rgba [255, 240, 200, 128]') }
kgl('kglLightShader', light.__id__, 15, 25, 200)
check 'the same light reuses its sprite', ObjectSpace.each_object(Sprite).select { |sp| sp.bitmap.equal?(light) }.length == 1
Graphics.update
check 'screen update runs the original update', Graphics.updates == 1
check 'a light drawn this frame stays visible', sprites[0].instance_variable_get(:@visible) == true
Graphics.update
check 'a light not drawn this frame is hidden', sprites[0].instance_variable_get(:@visible) == false
light.dispose
Graphics.update
check 'the sprite of a disposed light bitmap is disposed', sprites[0].disposed?

shadow_target = Bitmap.new(100, 100)
kgl('kglBindShadowbuffer', shadow_target.__id__)
kgl('kglShadowShaderH', 40, 60, 30)
rects = shadow_target.log.select { |e| e[0] == :clear_rect }
check 'wall above the light: shadow rows are above the wall', rects.all? { |e| e[2] < 30 } && rects.length == 30
check 'shadow widens away from the light', rects.first[3] == 50 && rects.first[1] == 25 && rects.last[3] == 22
kgl('kglUnbindShadowbuffer')
vertical = Bitmap.new(100, 100)
kgl('kglBindShadowbuffer', vertical.__id__)
kgl('kglShadowShaderV', 40, 60, 70)
check 'wall right of the light: shadow columns are right of the wall', vertical.log.select { |e| e[0] == :clear_rect }.all? { |e| e[1] >= 70 }
check 'vertical shadow at the far edge', vertical.log.include?([:clear_rect, 99, 25, 1, 50])
check 'unknown KGL function is tolerated', kgl('kglSoftShadows', 1) == 0
check 'other libraries are not taken over', Win32API.new('user32', 'Whatever', '', 'i').call == 0


ok = (5[0] == 1 && 5[0, 8] == 5 && 0b1100[2, 2] == 3 && 0b1100[2..3] == 3)
$stderr.puts('Integer#[] check') ; $failed = true unless ok
module JSON; def self.decode(j); j; end; end
check 'JSON.decode folds CRLF', JSON.decode("a\r\nb") == "a\nb"
module Graphics
  class << self
    def windowed_mode; @mode = :windowed; end
    def fullscreen_mode; @mode = :fullscreen; end
    def mode; @mode; end
  end
end
Graphics.fullscreen_mode
check 'Fullscreen++ fullscreen request becomes windowed mode', Graphics.mode == :windowed

class NexFakeChar
  attr_accessor :x, :y, :real_x, :real_y, :direction, :erased
  def initialize(x, y); @x = x; @y = y; @real_x = x; @real_y = y; @direction = 2; @erased = false; end
  def deleted?; false; end
end
module Sensors
  class Basic_Sensor
    def self.scan(character, targets = [])
      targets.select { |t| !t.equal?(character) }.map { |t| [t, 1, 1, 'x'] }
    end
    def self.signal_IgnoreCheck(c, t, m = false); false; end
    def self.not_actor?(t); false; end
    def self.ignore_obj_chk(c, t); false; end
    def self.mine_number(c, t, m); 0.5; end
    def self.get_mine_xy(c, t, m); [1, 2]; end
    def self.area_dimension; [10, 5]; end
    def self.calc_sight_hp_and_dist(c, t); [4, 1]; end
  end
end
$game_player = NexFakeChar.new(5, 5)
nex_enemy = NexFakeChar.new(5, 6)
nex_res = Sensors::Basic_Sensor.scan($game_player, [$game_player, nex_enemy])
check 'Sensors.scan still returns its result with the hit log on', nex_res.size == 1 && nex_res[0][0].equal?(nex_enemy)
hit_lines = $out.select { |l| l.to_s.include?('HIT ') }
check 'hit log: scan entry and report lines are written', hit_lines.any? { |l| l.include?('called on') } && hit_lines.any? { |l| l.include?('scan Sensors::Basic_Sensor') } && hit_lines.any? { |l| l.include?('counted') }
puts hit_lines.first(4)

class Game_Player; end
class Game_Actor
  def initialize; @action_state = :none; @skill_wait = 3; @current_skill_launched = false; end
  def process_skill_result(skill); :done; end
  def launch_effect_skill(skill); :launched; end
end
NexSkillLog.install
nex_actor = Game_Actor.new
check 'skill pipeline hooks keep the results', nex_actor.process_skill_result(nil) == :done && nex_actor.launch_effect_skill(Object.new) == :launched
NexSkillLog.install
check 'skill pipeline hooks install only once', nex_actor.process_skill_result(nil) == :done
exit($failed ? 1 : 0)

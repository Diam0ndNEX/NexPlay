import types, json, binascii, sys
exec(open('wrapper.py').read())
lib = open('lib.py').read()

class SD(dict):
    def __init__(s): dict.__init__(s); s.ever_been_changed=set()
renpy = types.ModuleType('renpy')
store = types.ModuleType('store'); sdict = SD()
store.__dict__.update({})
# make store.__dict__ the SD: use a simple object instead
class Store: pass
st = Store(); st.__dict__ = sdict
renpy.store = st
class Girl(object):
    def __init__(s): s.love = 3; s.name = "Amy"; s.items=[1,2]
sdict.update(dict(gold=100, name="Bob", flag=False, ratio=1.5, girl=Girl(), inv=[1,2,3], stats={'str':5,'int':7}, _hidden=1, f=len, none=None))
sdict.ever_been_changed.update(['gold','name','flag','ratio','girl','inv','stats','none'])
sdict['e'] = types.SimpleNamespace  # junk class
class Pers: pass
pers = Pers(); pers.cg1=False; pers.cg2=False; pers.score=10; pers._seen_ever={}; pers._seen_images={}; pers._seen_audio={}
renpy.game = types.SimpleNamespace(persistent=pers, script=types.SimpleNamespace(namemap={'start':1,'ch1':2,'_x':3,('f',1):4}),
    preferences=types.SimpleNamespace())
renpy.python = types.SimpleNamespace(store_dicts={'store': sdict})
renpy.config = types.SimpleNamespace(periodic_callbacks=[], name='Test', version='1.0', rollback_length=128)
renpy.display = types.SimpleNamespace(image=types.SimpleNamespace(images={('a','b'):1}))
renpy.get_filename_line = lambda: ('script.rpy', 12)
renpy.restart_interaction = lambda: None
renpy.save_persistent = lambda: None
renpy.has_label = lambda l: l in ('start','ch1')
renpy.jump = lambda l: print('JUMP', l)
renpy.call_in_new_context = lambda l: print('CALL', l)
renpy.list_files = lambda: ['a.ogg','b.png']
renpy.version = lambda: "Ren'Py 8.3.7"
renpy.store.achievement = types.SimpleNamespace(achievements={'a1'}, grant=lambda n: print('GRANT', n))

def call(req):
    hexs = binascii.hexlify(json.dumps(req).encode()).decode()
    g = {'renpy': renpy}
    code = lib + TAIL.replace('%HEX%', hexs)
    exec(code, g)
    assert '_nx_run' not in g
    return g['result']

r = json.loads(call({'op':'scan'})); print([ (x['n'],x['t'],x['v'],x['k']) for x in r['vars']]); print([x['n'] for x in r['pers']], r['at'])
print(json.loads(call({'op':'scan','all':True}))['vars'].__len__())
print(call({'op':'set','path':['s','gold'],'text':'999','how':'auto'}), sdict['gold'])
print(call({'op':'set','path':['s','name'],'text':'Zed','how':'str'}), sdict['name'])
print(call({'op':'set','path':['s','girl','a:love'],'text':'50','how':'auto'}), sdict['girl'].love)
print(call({'op':'set','path':['s','stats','k:str'],'text':'50','how':'auto'}), sdict['stats'])
print(call({'op':'set','path':['s','inv','i:1'],'text':'9','how':'auto'}), sdict['inv'])
print(call({'op':'toggle','path':['s','flag']}), sdict['flag'])
print(call({'op':'add','path':['s','gold'],'delta':1000}), sdict['gold'])
print(call({'op':'add','path':['s','ratio'],'delta':1}), sdict['ratio'])
print(call({'op':'add','path':['s','name'],'delta':1}))
print(json.loads(call({'op':'kids','path':['s','girl']}))['rows'])
print(json.loads(call({'op':'kids','path':['s','stats']}))['rows'])
print(json.loads(call({'op':'kids','path':['s','inv']}))['rows'][0])
print(call({'op':'lock','path':['s','gold'],'on':True}), len(renpy.config.periodic_callbacks))
sdict['gold']=1; renpy.config.periodic_callbacks[0](); print('locked back to', sdict['gold'])
print(json.loads(call({'op':'locks'}))['rows'])
print(call({'op':'unlock_locks'}))
print(call({'op':'bulk_bool','value':True,'match':'cg'}), pers.cg1, pers.cg2)
print(call({'op':'bulk_set','paths':[['s','gold'],['p','score']],'value':77}), sdict['gold'], pers.score)
print(call({'op':'unlock_all'}))
print(call({'op':'seen_all'}), len(pers._seen_ever))
print(call({'op':'rollback'}), renpy.config.rollback_length)
print(call({'op':'labels'}))
print(call({'op':'jump','label':'start'})); renpy.config.periodic_callbacks[-1]() if renpy.config.periodic_callbacks else None
print(call({'op':'jump','label':'nope'}))
print(call({'op':'exec','code':'gold * 2'}))
print(call({'op':'exec','code':'print("hi")\nnewvar = 5'}), sdict.get('newvar'))
print(call({'op':'exec','code':'1/0'}))
print(call({'op':'info'}))
print(call({'op':'bogus'}))

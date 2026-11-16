# The code the Swift side sends: library + call. HEX is replaced by the request.
TAIL = """
try:
    result = _nx_run(__import__('json').loads(__import__('binascii').unhexlify('%HEX%').decode('utf-8')))
except Exception as _e:
    result = 'ERR:' + repr(_e)
try:
    del _nx_run
except Exception:
    pass
"""

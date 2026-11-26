# test_i18n.py
"""Idiomas de py-installer: diccionarios completos, cada texto que usan el instalador y el actualizador
existe y recibe sus variables, y el montaje da un instalador por idioma, la pagina y pyi-lang.js."""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)
import pyi  # noqa: E402
import pyi_update  # noqa: E402

fails = []
VAR = re.compile(r'(?<!\{)\{([A-Za-z_][A-Za-z0-9_]*)\}(?!\})')


def ok(cond, what):
    print(('ok    ' if cond else 'FALLA ') + what)
    if not cond:
        fails.append(what)


def load(code):
    return json.load(open(os.path.join(ROOT, 'lang', 'pyi.%s.json' % code), encoding='utf-8'))


# ---------------------------------------------------------------- diccionarios
langs = pyi.pyi_langs()
ok(set(langs) >= {'es', 'en', 'ca'}, 'hay instalador en es, en y ca')
es = {k: v for k, v in load('es').items() if not k.startswith('@')}
for c in langs:
    d = {k: v for k, v in load(c).items() if not k.startswith('@')}
    ok(set(d) == set(es), '%s: las mismas claves que el original (faltan %s, sobran %s)' % (c, sorted(set(es) - set(d))[:5], sorted(set(d) - set(es))[:5]))
    bad = [k for k in es if k in d and set(VAR.findall(d[k])) != set(VAR.findall(es[k]))]
    ok(not bad, '%s: cada traduccion lleva las mismas {variables} (%s)' % (c, bad[:5]))
    ok(all(str(v).strip() for v in d.values()), '%s: nada vacio' % c)
ok({k[4:]: v for k, v in es.items() if k.startswith('upd.')} == pyi_update._ES,
   'los textos del actualizador en pyi.es.json son los de pyi_update._ES')

lk = os.path.join(ROOT, 'vendor', 'lang-kit')
ok(open(os.path.join(lk, 'VERSION')).read().strip() == re.search(r"LANGKIT_VERSION = '([^']+)'", open(os.path.join(lk, 'langkit.py')).read()).group(1),
   'la copia de lang-kit: VERSION coincide con LANGKIT_VERSION')


# ---------------------------------------------------------------- el instalador usa claves que existen
def calls(src, rx):
    """(clave, {variables pasadas}) de cada llamada: T 'clave' @{ a = ...; b = ... }."""
    out = []
    for m in rx.finditer(src):
        names = set()
        i = m.end()
        rest = src[i:i + 2]
        j = src.find('@{', i, i + 4)
        if j >= 0 and src[i:j].strip() == '':
            depth, k = 0, j + 1
            while k < len(src):
                if src[k] == '{':
                    depth += 1
                elif src[k] == '}':
                    depth -= 1
                    if depth == 0:
                        break
                k += 1
            body, flat, depth = src[j + 2:k], '', 0
            for ch in body:                        # solo el primer nivel: a = (x + @{ y = 1 })
                if ch in '({[':
                    depth += 1
                elif ch in ')}]':
                    depth -= 1
                elif depth == 0:
                    flat += ch
            names = set(re.findall(r'(?:^|;)\s*([A-Za-z_]\w*)\s*=', flat))
        del rest
        out.append((m.group(1), names))
    return out


tpl = open(os.path.join(ROOT, 'templates', 'install-windows.cmd'), encoding='utf-8').read()
used = calls(tpl, re.compile(r"\bT '([a-z0-9_.]+)'"))
ok(len(used) > 50, 'el instalador de Windows saca sus textos del diccionario (%d)' % len(used))
for key, names in used:
    if key not in es:
        ok(False, 'install-windows.cmd usa "%s", que no esta en pyi.es.json' % key)
    elif set(VAR.findall(es[key])) - names:
        ok(False, 'install-windows.cmd: a "%s" le faltan variables: %s' % (key, ', '.join(sorted(set(VAR.findall(es[key])) - names))))
need = {k for k in es if k.startswith(('inst.', 'uninst.'))} - {'inst.title_suffix', 'inst.optional'}
leftover = [ln for ln in tpl.splitlines() if re.search(r"(Say|Write-Host|throw)\s*\(?\s*'[^'_]*[a-z]{3,} [a-z]{3,}", ln)]
ok(not leftover, 'no quedan textos escritos a mano en el instalador: %s' % leftover[:2])

sh = open(os.path.join(ROOT, 'templates', 'install-unix.sh'), encoding='utf-8').read()
sh_used = set()
for line in sh.splitlines():
    for m in re.finditer(r'\$\(T ([a-z0-9_.]+)', line):
        key, names = m.group(1), set(re.findall(r'(?<=\s)([a-z_]+)=', line[m.end():]))
        sh_used.add(key)
        if key not in es:
            ok(False, 'install-unix.sh usa "%s", que no esta en pyi.es.json' % key)
        elif set(VAR.findall(es[key])) - names:
            ok(False, 'install-unix.sh: a "%s" le faltan variables: %s' % (key, ', '.join(sorted(set(VAR.findall(es[key])) - names))))
ok(len(sh_used) > 40, 'el instalador de Linux y macOS saca sus textos del diccionario (%d)' % len(sh_used))
ok(not need - {k for k, _ in used} - sh_used - {'inst.mac_command'}, 'todas las claves inst.*/uninst.* se usan en algun instalador')
leftover = [ln for ln in sh.splitlines() if re.search(r'(say|die|echo) "[A-Za-z¿]', ln)]
ok(not leftover, 'no quedan textos escritos a mano en el instalador de Linux y macOS: %s' % leftover[:2])

src = open(os.path.join(ROOT, 'pyi_update.py'), encoding='utf-8').read()
for key, kw in re.findall(r"""_t\('([a-z0-9_.]+)'((?:, [a-z_]+=[^,)]+(?:\([^)]*\))?)*)\)""", src):
    names = set(re.findall(r'([a-z_]+)=', kw))
    ok(key in pyi_update._ES and not set(VAR.findall(pyi_update._ES[key])) - names,
       'pyi_update: _t("%s") existe y recibe sus variables' % key)

# ---------------------------------------------------------------- montaje
tmp = tempfile.mkdtemp()
out = os.path.join(tmp, 'site')
pyi.build(os.path.join(ROOT, 'example'), 'http://127.0.0.1:8765', out, 'https://github.com/x/y', log=lambda *a: None)
dl = os.path.join(out, 'dl')
ok(os.path.exists(os.path.join(dl, 'hola-pyi-instalar.cmd')), 'el instalador en el idioma original conserva su nombre')
for c in ('en', 'ca'):
    ok(os.path.exists(os.path.join(dl, 'hola-pyi-instalar-%s.cmd' % c)), 'instalador de Windows en %s' % c)
for c in langs:
    name = 'hola-pyi-instalar.cmd' if c == 'es' else 'hola-pyi-instalar-%s.cmd' % c
    t = open(os.path.join(dl, name), encoding='utf-8').read()
    ok("$Lang        = '%s'" % c in t, '%s: el instalador sabe su idioma' % name)
    d = pyi.pyi_dict(c)
    missing = [k for k in d if k.startswith(('inst.', 'uninst.')) and ("    %s = " % pyi.ps_str(k)) not in t]
    ok(not missing, '%s: lleva todos sus textos (%s)' % (name, missing[:3]))
    title = t.splitlines()[4]
    ok(title.startswith('title ') and title.isascii(), '%s: la linea title es ASCII (%s)' % (name, title))
es_cmd = open(os.path.join(dl, 'hola-pyi-instalar.cmd'), encoding='utf-8').read()
ok("'Descargando {app}'" in es_cmd and "'Downloading {app}'" not in es_cmd, 'es: el instalador original sale en espanol (no en el idioma de reserva)')
for c in langs:
    ok(all(pyi.pyi_dict(c)[k] == v for k, v in load(c).items() if not k.startswith('@')), 'pyi_dict(%s) da los textos de pyi.%s.json' % (c, c))
en = open(os.path.join(dl, 'hola-pyi-instalar-en.cmd'), encoding='utf-8').read()
ok("'Downloading {app}'" in en and "$Description = 'py-installer sample program'" in en and "desc = 'Sample greeting'" in en,
   'en: textos del instalador y del manifiesto traducidos')
ok("why = 'test of an optional package that fails'" in en, 'en: el motivo de un opcional, traducido')
for c in langs:
    sfx = '' if c == 'es' else '-' + c
    p = os.path.join(dl, 'hola-pyi-instalar%s.sh' % sfx)
    ok(os.path.exists(p) and "LANG_CODE='%s'" % c in open(p, encoding='utf-8').read(), 'instalador de Linux en %s' % c)
    r = subprocess.run(['bash', '-n', p], capture_output=True, text=True) if shutil.which('bash') else None
    ok(r is None or r.returncode == 0, 'hola-pyi-instalar%s.sh: sintaxis de bash' % sfx)
    import zipfile
    names = zipfile.ZipFile(os.path.join(dl, 'hola-pyi-instalar-macos%s.zip' % sfx)).namelist()
    ok(names == [pyi.pyi_dict(c)['inst.mac_command'].replace('{app}', 'Hola py-installer')], 'zip de macOS en %s: %s' % (c, names))
sh_en = open(os.path.join(dl, 'hola-pyi-instalar-en.sh'), encoding='utf-8').read()
ok("'inst.step.download') printf %s 'Downloading {app}' ;;" in sh_en and "DESCRIPTION='py-installer sample program'" in sh_en
   and '<comment>Sample greeting</comment>' in sh_en, 'Linux en: textos del instalador y del manifiesto traducidos')
if shutil.which('bash'):   # la funcion T del instalador, tal cual, con el bash que haya (macOS trae el 3.2)
    head = sh_en[:sh_en.index('opt() {')]
    r = subprocess.run(['bash', '-c', head.split('set -euo pipefail', 1)[1] + '\nT inst.extra_fail_unix label=ffmpeg url=https://x/y files="a b" dir="/c d"; echo; T inst.ready app="A {app} & B"; echo; T no.existe'],
                       capture_output=True, text=True)
    ok(r.stdout.splitlines() == ['ffmpeg: could not be prepared. You can download it from https://x/y and copy a b to /c d; then run the installer again.',
                                 'Done. A {app} & B is installed.', 'no.existe'], 'T de bash: variables, valores raros y clave que no existe: %r' % r.stdout)
info = json.load(open(os.path.join(dl, 'app.json'), encoding='utf-8'))
ok(info['languages'][0] == 'es' and set(info['languages']) == set(langs), 'app.json: idiomas, el original primero')
ok(info['installers_by_lang']['en']['windows'].endswith('/dl/hola-pyi-instalar-en.cmd') and
   info['installers_by_lang']['ca']['linux'].endswith('/dl/hola-pyi-instalar-ca.sh') and info['installers']['linux'].endswith('/dl/hola-pyi-instalar.sh')
   and info['mac_commands']['en'] == 'Install Hola py-installer.command', 'app.json: instaladores por idioma')
upd = json.load(open(os.path.join(dl, 'update.json'), encoding='utf-8'))
for f in ('langkit.py', 'lang/es.json', 'lang/en.json', 'lang/pyi.ca.json', 'lang/common.en.json', 'pyi_update.py'):
    ok(f in upd['files'], 'update.json incluye %s' % f)
page = open(os.path.join(out, 'index.html'), encoding='utf-8').read()
ok('__' not in re.sub(r'__[a-z]', '', page.replace('__proto__', '')), 'pagina: no queda ninguna marca __X__ sin sustituir')
ok('"page.download_for": "Download for {os}"' in page and '"Català"' in page, 'pagina: lleva los textos de cada idioma')
ok(os.path.exists(os.path.join(dl, 'pyi-lang.js')), 'dl/pyi-lang.js para las paginas propias')

# hola.py, tal y como queda instalado (dl/ tiene langkit.py y lang/), saluda en el idioma pedido
for c, want in (('en', 'Hello! Installed'), ('ca', 'Hola! Instal·lat'), ('es', '¡Hola! Instalado')):
    r = subprocess.run([sys.executable, os.path.join(dl, 'hola.py'), '--check'], capture_output=True, text=True,
                       encoding='utf-8', env=dict(os.environ, LANGKIT_LANG=c, PYTHONIOENCODING='utf-8'))
    ok(want in r.stdout and (' %s ' % c) in r.stdout, 'hola.py --check en %s: %s' % (c, r.stdout.strip() or r.stderr[-200:]))
# y el actualizador habla el idioma del programa
r = subprocess.run([sys.executable, '-c', 'import sys; sys.path.insert(0, %r); import pyi_update; print(pyi_update._t("state.same"))' % dl],
                   capture_output=True, text=True, encoding='utf-8', env=dict(os.environ, LANGKIT_LANG='ca', PYTHONIOENCODING='utf-8'))
ok(r.stdout.strip() == "Tens l'última versió.", 'actualizador en catalan: %s' % (r.stdout.strip() or r.stderr[-200:]))
r = subprocess.run([sys.executable, '-I', '-c', 'import sys; sys.path.insert(0, %r); import pyi_update; print(pyi_update._t("state.same"))' % ROOT],
                   capture_output=True, text=True, encoding='utf-8', env=dict(os.environ, PYTHONIOENCODING='utf-8'))
ok(r.stdout.strip() == 'Tienes la última versión.', 'actualizador sin lang-kit: en espanol')

# pagina propia: se le anade pyi-lang.js si enlaza un instalador
app = os.path.join(tmp, 'propia')
shutil.copytree(os.path.join(ROOT, 'example'), app)
os.makedirs(os.path.join(app, 'site', 'sub'))
open(os.path.join(app, 'site', 'index.html'), 'w').write('<html><body><a href="__WINDOWS_URL__">Bajar</a></body></html>')
open(os.path.join(app, 'site', 'sub', 'otra.html'), 'w').write('<html><body><a href="__WINDOWS_URL__">x</a></body></html>')
open(os.path.join(app, 'site', 'nada.html'), 'w').write('<html><body>sin enlaces</body></html>')
open(os.path.join(app, 'site', 'relativa.html'), 'w').write('<html><body><a href="dl/hola-pyi-instalar.cmd">x</a></body></html>')
o2 = os.path.join(tmp, 's2')
pyi.build(app, 'https://x.example', o2, log=lambda *a: None)
ok('<script src="dl/pyi-lang.js" defer></script>' in open(os.path.join(o2, 'index.html')).read(), 'pagina propia: lleva pyi-lang.js')
ok('src="../dl/pyi-lang.js"' in open(os.path.join(o2, 'sub', 'otra.html')).read(), 'pagina propia en subcarpeta: ruta relativa')
ok('pyi-lang.js' not in open(os.path.join(o2, 'nada.html')).read(), 'una pagina sin instaladores no se toca')
ok('pyi-lang.js' in open(os.path.join(o2, 'relativa.html')).read(), 'una pagina con enlaces relativos (dl/...) tambien lo lleva')
ok("return match('en') || D.source;" in open(os.path.join(o2, 'dl', 'pyi-lang.js'), encoding='utf-8').read(), 'pyi-lang.js: un idioma que no hay, en ingles')
js = open(os.path.join(o2, 'dl', 'pyi-lang.js'), encoding='utf-8').read()
links = json.loads(re.search(r'var D = (\{.*\});', js).group(1))['links']
ok(links['https://x.example/dl/hola-pyi-instalar.cmd'] == {'es': 'https://x.example/dl/hola-pyi-instalar.cmd', 'ca': 'https://x.example/dl/hola-pyi-instalar-ca.cmd',
                                                           'en': 'https://x.example/dl/hola-pyi-instalar-en.cmd'},
   'pyi-lang.js: cada instalador con su version en cada idioma')

# solo un idioma, o sin lang-kit
t = open(os.path.join(app, 'py-installer.toml'), encoding='utf-8').read()
open(os.path.join(app, 'py-installer.toml'), 'w', encoding='utf-8').write(t.replace('[i18n.en]', '[i18n]\nlanguages = ["es"]\n\n[i18n.en]', 1))
o3 = os.path.join(tmp, 's3')
pyi.build(app, 'https://x.example', o3, log=lambda *a: None)
ok(not os.path.exists(os.path.join(o3, 'dl', 'hola-pyi-instalar-en.cmd')) and os.path.exists(os.path.join(o3, 'dl', 'lang', 'pyi.es.json'))
   and not os.path.exists(os.path.join(o3, 'dl', 'lang', 'pyi.en.json')), 'languages = ["es"]: un solo instalador y solo sus textos')
ok('pyi-lang.js' not in open(os.path.join(o3, 'index.html')).read(), 'con un solo idioma no hace falta pyi-lang.js')
open(os.path.join(app, 'py-installer.toml'), 'w', encoding='utf-8').write(t.replace('[i18n.en]', '[i18n]\nenabled = false\n\n[i18n.en]', 1))
m = pyi.load_manifest(app)
ok('langkit.py' not in m['files'] and not any(f.startswith('lang/') for f in m['files']) and 'lang.json' not in m['keep'],
   'enabled = false: ni langkit.py ni diccionarios')
open(os.path.join(app, 'py-installer.toml'), 'w', encoding='utf-8').write(t.replace('[i18n.en]', '[i18n]\nlanguages = ["es", "xx"]\n\n[i18n.en]', 1))
try:
    pyi.load_manifest(app)
    ok(False, 'un idioma sin instalador se rechaza')
except pyi.ManifestError as e:
    ok('xx' in str(e), 'un idioma sin instalador se rechaza')
shutil.rmtree(tmp, ignore_errors=True)

print('TODO OK' if not fails else '%d FALLOS' % len(fails))
sys.exit(1 if fails else 0)

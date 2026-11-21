#!/usr/bin/env python3
# pyi.py
"""py-installer: convierte un programa de Python en una app instalable con un clic en Windows,
Linux y macOS (instalador sin administrador, Python propio con uv, accesos directos, desinstalador,
pagina de descarga y update.json para que el programa pueda actualizarse solo).

Uso:
  python3 pyi.py build --app <carpeta del programa> --base <URL del sitio> [--out _site] [--repo URL]
  python3 pyi.py check --app <carpeta>           valida el manifiesto sin montar nada
  python3 pyi.py init  [carpeta]                 crea py-installer.toml y el workflow de GitHub Pages

Todo se describe en <carpeta>/py-installer.toml (ver templates/py-installer.toml).
"""
import argparse
import hashlib
import html
import json
import os
import re
import shutil
import sys
import zipfile

try:
    import tomllib
except ImportError:  # Python < 3.11
    sys.exit('py-installer necesita Python 3.11 o mas nuevo (por tomllib).')

HERE = os.path.dirname(os.path.abspath(__file__))
TPL = os.path.join(HERE, 'templates')
MANIFEST = 'py-installer.toml'
UPDATER = 'pyi_update.py'          # actualizador comun: se instala junto a cada programa
ALL_OS = ('windows', 'linux', 'macos')
OS_LABEL = {'windows': 'Windows', 'linux': 'Linux', 'macos': 'macOS'}


def pyi_version():
    try:
        return open(os.path.join(HERE, 'VERSION'), encoding='utf-8').read().strip()
    except OSError:
        return '0'


class ManifestError(Exception):
    pass


# ---------------------------------------------------------------------------------------------
# Manifiesto
# ---------------------------------------------------------------------------------------------
def load_manifest(app_dir, repo_url=''):
    path = os.path.join(app_dir, MANIFEST)
    if not os.path.exists(path):
        raise ManifestError(f'no existe {path} (crealo con: python3 pyi.py init {app_dir})')
    with open(path, 'rb') as f:
        raw = tomllib.load(f)
    errs = []
    a = raw.get('app', {})
    for k in ('id', 'name', 'entry'):
        if not a.get(k):
            errs.append(f'[app] {k} es obligatorio')
    if errs:
        raise ManifestError('; '.join(errs))
    app_id = a['id']
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]*', app_id):
        errs.append('[app] id: solo minusculas, digitos y guiones (p.ej. "md-reader")')
    owner = ''
    m = re.match(r'https://github\.com/([^/]+)/', repo_url + '/')
    if m:
        owner = m.group(1)
    oses = [o.lower() for o in a.get('os', list(ALL_OS))]
    for o in oses:
        if o not in ALL_OS:
            errs.append(f'[app] os: "{o}" no es valido (usa {", ".join(ALL_OS)})')
    if not oses:
        errs.append('[app] os: hace falta al menos un sistema')
    py = str(a.get('python', '3.12'))
    if not re.fullmatch(r'3\.\d+', py):
        errs.append('[app] python: algo como "3.12"')
    files = [a['entry']] + [f for f in a.get('files', []) if f != a['entry'] and f != UPDATER]
    hooks = raw.get('hooks', {})
    post = hooks.get('post_install', '')
    if post and post not in files:
        files.append(post)
    for f in files:
        if os.path.isabs(f) or '..' in f.replace('\\', '/').split('/'):
            errs.append(f'{f}: usa rutas relativas dentro del repo')
        elif not os.path.isfile(os.path.join(app_dir, f)):
            errs.append(f'no existe el archivo {f}')
    gui = bool(a.get('gui', True))
    updater = bool(a.get('updater', True))
    venv = a.get('venv', '.venv')
    if not re.fullmatch(r'[A-Za-z0-9._-]+', venv):
        errs.append('[app] venv: un nombre de carpeta sencillo (p.ej. ".venv")')
    deps = raw.get('deps', {})
    required = list(deps.get('required', []))
    if deps.get('requirements'):
        rp = os.path.join(app_dir, deps['requirements'])
        if not os.path.isfile(rp):
            errs.append(f'no existe {deps["requirements"]}')
        else:
            for line in open(rp, encoding='utf-8'):
                line = line.split('#', 1)[0].strip()
                if line and not line.startswith('-'):
                    required.append(line)
    optional = []
    for o in deps.get('optional', []):
        if isinstance(o, str):
            o = {'pkg': o}
        if not o.get('pkg'):
            errs.append('[deps] optional: cada entrada necesita "pkg"')
            continue
        optional.append({'pkg': o['pkg'], 'why': o.get('why', 'opcional')})
    req_names = {re.split(r'[<>=!~\[; ]', r, maxsplit=1)[0].lower() for r in required}
    optional = [o for o in optional if re.split(r'[<>=!~\[; ]', o['pkg'], maxsplit=1)[0].lower() not in req_names]
    chk = raw.get('check', {})
    check_code = chk.get('code', 'import tkinter; tkinter.Tcl()' if gui else '')
    check_env = {str(k): str(v) for k, v in chk.get('env', {}).items()}
    if '"' in check_code:
        errs.append('[check] code: usa comillas simples (PowerShell 5.1 estropea las dobles al pasarlas a Python)')
    icon = raw.get('icon', {})
    for k in ('png', 'ico', 'icns'):
        if icon.get(k) and not os.path.isfile(os.path.join(app_dir, icon[k])):
            errs.append(f'[icon] {k}: no existe {icon[k]}')
    data = raw.get('data', {})
    if data.get('zip') and not os.path.isdir(os.path.join(app_dir, data['zip'])):
        errs.append(f'[data] zip: no existe la carpeta {data["zip"]}')
    extras = []
    for x in raw.get('extra', []):
        xo = x.get('os', 'any')
        xos = [xo] if isinstance(xo, str) else list(xo)
        if not x.get('url') or not x.get('extract'):
            errs.append('[[extra]] necesita url y extract')
            continue
        extras.append({'os': xos, 'url': x['url'], 'extract': list(x['extract']), 'to': x.get('to', '.'),
                       'label': x.get('label', os.path.basename(x['url'])), 'required': bool(x.get('required', True))})
    site = raw.get('site', {})
    folder = a.get('folder', app_id)
    if not re.fullmatch(r'[A-Za-z0-9._ -]+', folder):
        errs.append('[app] folder: solo letras, digitos, espacios, puntos, guiones y _')
    link = re.sub(r'[\\/:*?"<>|]', '', a['name']).strip() or app_id
    if errs:
        raise ManifestError('; '.join(errs))
    return {
        'id': app_id, 'name': a['name'], 'entry': a['entry'], 'files': files + ([UPDATER] if updater else []),
        'updater': updater, 'venv': venv,
        'description': a.get('description', a['name']),
        'publisher': a.get('publisher', owner or a['name']),
        'owner': owner or 'local',
        'gui': gui, 'python': py, 'os': [o for o in ALL_OS if o in oses],
        'folder': folder, 'link_name': link,
        'env_prefix': a.get('env_prefix', re.sub(r'[^A-Z0-9]', '_', app_id.upper())),
        'desktop': bool(a.get('desktop_shortcut', True)),
        'issues_url': a.get('issues_url', (repo_url.rstrip('/') + '/issues') if repo_url else ''),
        'icon': icon, 'required': required, 'optional': optional,
        'check_code': check_code, 'check_env': check_env,
        'data_zip': data.get('zip', ''),
        'keep': list(data.get('keep', [])) + (['actualizacion.json'] if updater and 'actualizacion.json' not in data.get('keep', []) else []),
        'extras': extras, 'post_install': post,
        'site_dir': site.get('dir', 'site'),
        'names': {'windows': site.get('windows_name', 'install-windows.cmd'),
                  'linux': site.get('linux_name', 'install-linux.sh'),
                  'macos': site.get('macos_name', 'install-macos.zip')},
    }


def read_version(app_dir, m):
    vp = os.path.join(app_dir, 'VERSION')
    src = open(os.path.join(app_dir, m['entry']), encoding='utf-8').read()
    appver = re.search(r'^APP_VERSION\s*=\s*["\']([^"\']+)["\']', src, re.M)
    if os.path.exists(vp):
        ver = open(vp, encoding='utf-8').read().strip()
        if appver and appver.group(1) != ver:
            raise ManifestError(f'APP_VERSION ({appver.group(1)}) no coincide con VERSION ({ver})')
    elif appver:
        ver = appver.group(1)
    else:
        raise ManifestError('falta el archivo VERSION (o APP_VERSION = "x.y.z" en el programa)')
    pack = re.search(r'^APP_PACK\s*=\s*(\d+)', src, re.M)
    return ver, (int(pack.group(1)) if pack else None)


# ---------------------------------------------------------------------------------------------
# Configuracion incrustada en los instaladores
# ---------------------------------------------------------------------------------------------
def ps_str(s):
    return "'" + str(s).replace("'", "''") + "'"


def ps_arr(items):
    return '@(' + ', '.join(ps_str(i) for i in items) + ')'


def ps_config(m, base, version, has):
    opt = ', '.join('@{ pkg = %s; why = %s }' % (ps_str(o['pkg']), ps_str(o['why'])) for o in m['optional'])
    extras = [x for x in m['extras'] if 'windows' in x['os'] or 'any' in x['os']]
    ex = ', '.join('@{ url = %s; extract = %s; to = %s; label = %s; required = %s }' % (
        ps_str(x['url']), ps_arr(x['extract']), ps_str(x['to'].replace('/', '\\')), ps_str(x['label']),
        '$true' if x['required'] else '$false') for x in extras)
    env = '; '.join('%s = %s' % (ps_str(k), ps_str(v)) for k, v in m['check_env'].items())
    b = lambda v: '$true' if v else '$false'
    lines = [
        '# --- generado por py-installer %s: datos del programa ---' % pyi_version(),
        '$PyiVersion  = %s' % ps_str(pyi_version()),
        '$Base        = %s' % ps_str(base),
        '$AppId       = %s' % ps_str(m['id']),
        '$AppName     = %s' % ps_str(m['name']),
        '$Description = %s' % ps_str(m['description']),
        '$Publisher   = %s' % ps_str(m['publisher']),
        '$Entry       = %s' % ps_str(m['entry']),
        '$Files       = %s' % ps_arr(m['files']),
        '$Gui         = %s' % b(m['gui']),
        '$VenvDir     = %s' % ps_str(m['venv']),
        '$PyVer       = %s' % ps_str(m['python']),
        '$Folder      = %s' % ps_str(m['folder']),
        '$LinkName    = %s' % ps_str(m['link_name']),
        '$EnvPrefix   = %s' % ps_str(m['env_prefix']),
        '$Desktop     = %s' % b(m['desktop']),
        '$IssuesUrl   = %s' % ps_str(m['issues_url'] or base),
        '$HasIco      = %s' % b(has['ico']),
        '$Required    = %s' % ps_arr(m['required']),
        '$Optional    = @(%s)' % opt,
        '$CheckCode   = %s' % ps_str(m['check_code']),
        '$CheckEnv    = @{ %s }' % env,
        '$DataZip     = %s' % ps_str('data.zip' if m['data_zip'] else ''),
        '$Keep        = %s' % ps_arr(m['keep']),
        '$Extras      = @(%s)' % ex,
        '$PostInstall = %s' % ps_str(m['post_install']),
        '# --- fin de los datos del programa ---',
    ]
    return '\n'.join(lines)


def sh_str(s):
    return "'" + str(s).replace("'", "'\\''") + "'"


def sh_arr(items):
    return '(' + ' '.join(sh_str(i) for i in items) + ')'


def sh_config(m, base, version, has):
    extras = [x for x in m['extras'] if set(x['os']) & {'linux', 'macos', 'any'}]
    osmap = lambda x: ' '.join({'macos': 'mac'}.get(o, o) for o in x['os'])
    for x in extras:
        for n in x['extract']:
            if ' ' in n:
                raise ManifestError(f'[[extra]] extract: "{n}" no puede tener espacios')
    lines = [
        '# --- generado por py-installer %s: datos del programa ---' % pyi_version(),
        'PYI_VERSION=%s' % sh_str(pyi_version()),
        'BASE=%s' % sh_str(base),
        'APP_ID=%s' % sh_str(m['id']),
        'APP_NAME=%s' % sh_str(m['name']),
        'DESCRIPTION=%s' % sh_str(m['description']),
        'BUNDLE_OWNER=%s' % sh_str(re.sub(r'[^A-Za-z0-9-]', '-', m['owner']).lower()),
        'ENTRY=%s' % sh_str(m['entry']),
        'FILES=%s' % sh_arr(m['files']),
        'GUI=%s' % (1 if m['gui'] else 0),
        'VENV_DIR=%s' % sh_str(m['venv']),
        'PY_VER=%s' % sh_str(m['python']),
        'FOLDER=%s' % sh_str(m['folder']),
        'LINK_NAME=%s' % sh_str(m['link_name']),
        'ENV_PREFIX=%s' % sh_str(m['env_prefix']),
        'DESKTOP=%s' % (1 if m['desktop'] else 0),
        'ISSUES_URL=%s' % sh_str(m['issues_url'] or base),
        'SUPPORTS_LINUX=%s' % (1 if 'linux' in m['os'] else 0),
        'SUPPORTS_MACOS=%s' % (1 if 'macos' in m['os'] else 0),
        'HAS_PNG=%s' % (1 if has['png'] else 0),
        'HAS_ICNS=%s' % (1 if has['icns'] else 0),
        'REQUIRED=%s' % sh_arr(m['required']),
        'OPTIONAL_PKG=%s' % sh_arr(o['pkg'] for o in m['optional']),
        'OPTIONAL_WHY=%s' % sh_arr(o['why'] for o in m['optional']),
        'CHECK_CODE=%s' % sh_str(m['check_code']),
        'CHECK_ENV=%s' % sh_arr(f'{k}={v}' for k, v in m['check_env'].items()),
        'DATA_ZIP=%s' % sh_str('data.zip' if m['data_zip'] else ''),
        'KEEP=%s' % sh_arr(m['keep']),
        'EX_OS=%s' % sh_arr(osmap(x) for x in extras),
        'EX_URL=%s' % sh_arr(x['url'] for x in extras),
        'EX_EXTRACT=%s' % sh_arr(' '.join(x['extract']) for x in extras),
        'EX_TO=%s' % sh_arr(x['to'] for x in extras),
        'EX_LABEL=%s' % sh_arr(x['label'] for x in extras),
        'EX_REQ=%s' % sh_arr('1' if x['required'] else '0' for x in extras),
        'POST_INSTALL=%s' % sh_str(m['post_install']),
        '# --- fin de los datos del programa ---',
    ]
    return '\n'.join(lines)


def render(template, marker_line, config):
    src = open(os.path.join(TPL, template), encoding='utf-8').read()
    if marker_line not in src:
        raise RuntimeError(f'{template}: falta la marca {marker_line}')
    return src.replace(marker_line, config, 1)


# ---------------------------------------------------------------------------------------------
# Iconos
# ---------------------------------------------------------------------------------------------
def prepare_icons(app_dir, m, dl, log):
    icon = m['icon']
    has = {'png': False, 'ico': False, 'icns': False}
    for k in has:
        if icon.get(k):
            shutil.copyfile(os.path.join(app_dir, icon[k]), os.path.join(dl, 'icon.' + k))
            has[k] = True
    if has['png'] and not (has['ico'] and has['icns']):
        try:
            from PIL import Image
        except ImportError:
            log('aviso: sin Pillow no se pueden generar .ico/.icns desde el png (pip install pillow)')
            return has
        img = Image.open(os.path.join(dl, 'icon.png')).convert('RGBA')
        side = max(img.size)
        if img.size[0] != img.size[1]:
            sq = Image.new('RGBA', (side, side), (0, 0, 0, 0))
            sq.paste(img, ((side - img.size[0]) // 2, (side - img.size[1]) // 2))
            img = sq
        if not has['ico']:
            img.save(os.path.join(dl, 'icon.ico'), sizes=[(s, s) for s in (16, 24, 32, 48, 64, 128, 256) if s <= side])
            has['ico'] = True
            log('icon.ico generado desde el png')
        if not has['icns']:
            try:
                big = img.resize((1024, 1024), Image.LANCZOS) if side < 1024 else img
                big.save(os.path.join(dl, 'icon.icns'))
                has['icns'] = True
                log('icon.icns generado desde el png')
            except Exception as e:  # noqa: BLE001
                log(f'aviso: no se pudo generar icon.icns ({e})')
    return has


# ---------------------------------------------------------------------------------------------
# Montaje del sitio
# ---------------------------------------------------------------------------------------------
def sha256(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def zip_dir(src, dest):
    with zipfile.ZipFile(dest, 'w', zipfile.ZIP_DEFLATED) as z:
        for root, dirs, files in os.walk(src):
            dirs.sort()
            for f in sorted(files):
                p = os.path.join(root, f)
                zi = zipfile.ZipInfo(os.path.relpath(p, src).replace(os.sep, '/'), (2020, 1, 1, 0, 0, 0))
                zi.compress_type = zipfile.ZIP_DEFLATED
                zi.external_attr = 0o644 << 16
                z.writestr(zi, open(p, 'rb').read())


def build(app_dir, base, out, repo_url='', log=print):
    app_dir = os.path.abspath(app_dir)
    base = base.rstrip('/')
    m = load_manifest(app_dir, repo_url)
    version, pack = read_version(app_dir, m)
    if os.path.exists(out):
        shutil.rmtree(out)
    dl = os.path.join(out, 'dl')
    os.makedirs(dl)

    # el programa
    for f in m['files']:
        d = os.path.join(dl, f)
        os.makedirs(os.path.dirname(d), exist_ok=True)
        src = os.path.join(HERE, UPDATER) if f == UPDATER else os.path.join(app_dir, f)
        shutil.copyfile(src, d)
    with open(os.path.join(dl, 'VERSION'), 'w', encoding='utf-8') as fh:
        fh.write(version + '\n')
    has = prepare_icons(app_dir, m, dl, log)
    if m['data_zip']:
        zip_dir(os.path.join(app_dir, m['data_zip']), os.path.join(dl, 'data.zip'))

    # los instaladores
    urls = {}
    if 'windows' in m['os']:
        txt = render('install-windows.cmd', '# @@PYI_CONFIG@@', ps_config(m, base, version, has))
        txt = txt.replace('__PYI_TITLE__', re.sub(r'[&|<>^%"]', '', m['name'])).replace('__PYI_ID__', m['id'])
        name = m['names']['windows']
        with open(os.path.join(dl, name), 'w', encoding='utf-8', newline='\r\n') as fh:
            fh.write(txt)
        urls['windows'] = f'{base}/dl/{name}'
    if 'linux' in m['os'] or 'macos' in m['os']:
        txt = render('install-unix.sh', '# @@PYI_CONFIG@@', sh_config(m, base, version, has))
        if 'linux' in m['os']:
            name = m['names']['linux']
            p = os.path.join(dl, name)
            with open(p, 'w', encoding='utf-8', newline='\n') as fh:
                fh.write(txt)
            os.chmod(p, 0o755)
            urls['linux'] = f'{base}/dl/{name}'
        if 'macos' in m['os']:
            name = m['names']['macos']
            zi = zipfile.ZipInfo(f'Instalar {m["link_name"]}.command', (2020, 1, 1, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = (0o100755 << 16)   # ejecutable al descomprimir con el Finder
            zi.create_system = 3
            with zipfile.ZipFile(os.path.join(dl, name), 'w') as z:
                z.writestr(zi, txt.encode('utf-8'))
            urls['macos'] = f'{base}/dl/{name}'

    # update.json: lo que lee "Buscar actualizaciones" en el programa
    notes = ''
    np = os.path.join(app_dir, 'NOVEDADES.md')
    if os.path.exists(np):
        notes = open(np, encoding='utf-8').read()[:4000]
    upd = {'version': version, 'notes': notes,
           'files': {f: {'sha256': sha256(os.path.join(dl, f)), 'size': os.path.getsize(os.path.join(dl, f))}
                     for f in m['files']}}
    if pack is not None:
        upd = {'pack': pack, **upd}
    with open(os.path.join(dl, 'update.json'), 'w', encoding='utf-8') as fh:
        json.dump(upd, fh, ensure_ascii=False, indent=2)

    # app.json: datos para la pagina (que sistemas tienen instalador y donde estan)
    info = {'id': m['id'], 'name': m['name'], 'description': m['description'], 'version': version,
            'pack': pack, 'os': m['os'], 'installers': urls, 'repo': repo_url, 'py_installer': pyi_version()}
    with open(os.path.join(dl, 'app.json'), 'w', encoding='utf-8') as fh:
        json.dump(info, fh, ensure_ascii=False, indent=2)

    # la pagina
    subs = {
        '__BASE_URL__': base, '__VERSION__': version, '__PACK__': str(pack if pack is not None else ''),
        '__REPO_URL__': repo_url, '__NAME__': html.escape(m['name']),
        '__DESCRIPTION__': html.escape(m['description']),
        '__WINDOWS_URL__': urls.get('windows', ''), '__LINUX_URL__': urls.get('linux', ''),
        '__MACOS_URL__': urls.get('macos', ''),
    }
    site_src = os.path.join(app_dir, m['site_dir'])
    if os.path.isdir(site_src):
        for root, dirs, files in os.walk(site_src):
            rel = os.path.relpath(root, site_src)
            os.makedirs(os.path.join(out, rel), exist_ok=True)
            for f in files:
                s, d = os.path.join(root, f), os.path.join(out, rel, f)
                if f.endswith(('.html', '.htm', '.js', '.css', '.json', '.txt', '.webmanifest')):
                    t = open(s, encoding='utf-8').read()
                    for k, v in subs.items():
                        t = t.replace(k, v)
                    open(d, 'w', encoding='utf-8').write(t)
                else:
                    shutil.copyfile(s, d)
        log(f'pagina: {m["site_dir"]}/ (propia)')
    else:
        t = open(os.path.join(TPL, 'index.html'), encoding='utf-8').read()
        subs['__APP_JSON__'] = json.dumps(info, ensure_ascii=False).replace('</', '<\\/')
        subs['__OS_LIST__'] = ', '.join(OS_LABEL[o] for o in m['os'])
        subs['__HAS_ICON__'] = '1' if has['png'] else ''
        for k, v in subs.items():
            t = t.replace(k, v)
        open(os.path.join(out, 'index.html'), 'w', encoding='utf-8').write(t)
        if has['png']:
            shutil.copyfile(os.path.join(dl, 'icon.png'), os.path.join(out, 'favicon.png'))
        log('pagina: generada por py-installer')
    open(os.path.join(out, '.nojekyll'), 'w').close()
    log(f'{m["name"]} {version}' + (f' (pack {pack})' if pack is not None else '') +
        f': instaladores para {", ".join(OS_LABEL[o] for o in m["os"])} -> {out}')
    return info


# ---------------------------------------------------------------------------------------------
# init
# ---------------------------------------------------------------------------------------------
def init(app_dir):
    app_dir = os.path.abspath(app_dir)
    if not os.path.isdir(app_dir):
        raise ManifestError(f'no existe la carpeta {app_dir}')
    mp = os.path.join(app_dir, MANIFEST)
    if os.path.exists(mp):
        print(f'{MANIFEST} ya existe: no lo toco')
    else:
        pys = sorted(f for f in os.listdir(app_dir) if f.endswith('.py') and not f.startswith(('test_', 'setup')))
        entry = pys[0] if pys else 'main.py'
        app_id = re.sub(r'[^a-z0-9-]+', '-', os.path.basename(app_dir).lower()).strip('-') or 'mi-app'
        t = open(os.path.join(TPL, MANIFEST), encoding='utf-8').read()
        t = t.replace('id = "mi-app"', f'id = "{app_id}"').replace('name = "Mi App"', f'name = "{app_id}"')
        t = t.replace('entry = "mi_app.py"', f'entry = "{entry}"')
        if os.path.exists(os.path.join(app_dir, 'requirements.txt')):
            t = t.replace('# requirements = "requirements.txt"', 'requirements = "requirements.txt"')
        open(mp, 'w', encoding='utf-8').write(t)
        print(f'creado {MANIFEST} (entry = {entry}); revisalo')
    if not os.path.exists(os.path.join(app_dir, 'VERSION')):
        open(os.path.join(app_dir, 'VERSION'), 'w').write('0.1.0\n')
        print('creado VERSION (0.1.0)')
    wf = os.path.join(app_dir, '.github', 'workflows', 'pages.yml')
    if os.path.exists(wf):
        print('.github/workflows/pages.yml ya existe: no lo toco (mira templates/pages.yml)')
    else:
        os.makedirs(os.path.dirname(wf), exist_ok=True)
        shutil.copyfile(os.path.join(TPL, 'pages.yml'), wf)
        print('creado .github/workflows/pages.yml; activa Pages con origen "GitHub Actions" en los ajustes del repo')


def main(argv=None):
    ap = argparse.ArgumentParser(prog='pyi.py', description='py-installer ' + pyi_version())
    sub = ap.add_subparsers(dest='cmd', required=True)
    b = sub.add_parser('build', help='monta la pagina, los instaladores y update.json')
    b.add_argument('--app', default='.', help='carpeta del programa (con py-installer.toml)')
    b.add_argument('--base', required=True, help='URL base del sitio, p.ej. https://usuario.github.io/repo')
    b.add_argument('--out', default='_site')
    b.add_argument('--repo', default='', help='URL del repo de GitHub (enlaces e issues)')
    c = sub.add_parser('check', help='valida el manifiesto')
    c.add_argument('--app', default='.')
    i = sub.add_parser('init', help='prepara un programa para usar py-installer')
    i.add_argument('app', nargs='?', default='.')
    sub.add_parser('version')
    args = ap.parse_args(argv)
    try:
        if args.cmd == 'build':
            build(args.app, args.base, args.out, args.repo)
        elif args.cmd == 'check':
            m = load_manifest(args.app)
            v, p = read_version(args.app, m)
            print(f'ok: {m["name"]} {v}, sistemas: {", ".join(m["os"])}, archivos: {", ".join(m["files"])}')
        elif args.cmd == 'init':
            init(args.app)
        else:
            print(pyi_version())
    except ManifestError as e:
        sys.exit(f'py-installer: {e}')


if __name__ == '__main__':
    main()

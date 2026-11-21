# test_update.py
"""Prueba del actualizador comun (pyi_update.py) contra un sitio servido en local:
publicar 1.0.0, "instalar", publicar 1.0.1 con un archivo nuevo, comprobar, aplicar, volver atras,
y volver atras desde una copia del formato antiguo (un archivo suelto).
Uso: python3 tests/test_update.py"""
import functools
import http.server
import json
import os
import shutil
import sys
import tempfile
import threading

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
import pyi            # noqa: E402
import pyi_update     # noqa: E402


def ok(cond, msg):
    if not cond:
        sys.exit('FALLO: ' + msg)
    print('ok -', msg)


def main():
    tmp = tempfile.mkdtemp(prefix='pyi-upd-')
    site = os.path.join(tmp, 'site')
    app = os.path.join(tmp, 'app')
    shutil.copytree(os.path.join(HERE, 'example'), app)
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=site)
    os.makedirs(site)
    srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = 'http://127.0.0.1:%d' % srv.server_address[1]
    quiet = lambda *a: None

    # 1.0.0 publicada e "instalada" (lo mismo que deja el instalador en la carpeta del programa)
    pyi.build(app, base, site, log=quiet)
    inst = os.path.join(tmp, 'instalado')
    os.makedirs(inst)
    for f in ('hola.py', 'pyi_update.py', 'VERSION'):
        shutil.copyfile(os.path.join(site, 'dl', f), os.path.join(inst, f))
    json.dump({'id': 'hola-pyi', 'base_url': base, 'version': '1.0.0'}, open(os.path.join(inst, 'install_info.json'), 'w'))
    U = pyi_update.Updater(os.path.join(inst, 'hola.py'))
    ok(U.enabled and U.base == base + '/dl/', 'la direccion sale de install_info.json')
    r = U.check()
    ok(r['ok'] and r['state'] == 'same', 'recien instalado: misma version (%s)' % r.get('state'))

    # 1.0.1 con un modulo nuevo
    src = open(os.path.join(app, 'hola.py'), encoding='utf-8').read().replace('APP_VERSION = "1.0.0"', 'APP_VERSION = "1.0.1"')
    open(os.path.join(app, 'hola.py'), 'w', encoding='utf-8').write(src)
    open(os.path.join(app, 'VERSION'), 'w').write('1.0.1\n')
    open(os.path.join(app, 'extra.py'), 'w').write('X = 1\n')
    t = open(os.path.join(app, 'py-installer.toml'), encoding='utf-8').read()
    open(os.path.join(app, 'py-installer.toml'), 'w', encoding='utf-8').write(t.replace('entry = "hola.py"', 'entry = "hola.py"\nfiles = ["extra.py"]'))
    pyi.build(app, base, site, log=quiet)
    r = U.check()
    ok(r['ok'] and r['state'] == 'newer', 'detecta la 1.0.1')
    U.set_auto_apply(True)
    ok(U.startup_action(r) == 'apply', 'con "actualizar sin preguntar", al abrir aplica')
    U.set_auto_apply(False)
    ok(U.startup_action(r) == 'ask', 'sin ella, pregunta')
    res = U.apply(r['info'])
    ok(set(res['files']) == {'hola.py', 'extra.py'}, 'aplica solo lo que cambia: %s' % res['files'])
    ok(os.path.exists(os.path.join(inst, 'extra.py')), 'el archivo nuevo llega')
    ok(open(os.path.join(inst, 'VERSION')).read().strip() == '1.0.1', 'VERSION actualizado')
    U2 = pyi_update.Updater(os.path.join(inst, 'hola.py'))
    ok(U2.check()['state'] == 'same', 'tras actualizar: misma version')

    # volver atras
    ok(U2.backup_available(), 'hay copia para volver atras')
    U2.rollback()
    ok('APP_VERSION = "1.0.0"' in open(os.path.join(inst, 'hola.py'), encoding='utf-8').read(), 'vuelve a la 1.0.0')
    ok(not os.path.exists(os.path.join(inst, 'extra.py')), 'quita lo que habia anadido la actualizacion')
    ok(open(os.path.join(inst, 'VERSION')).read().strip() == '1.0.0', 'VERSION restaurado')

    # copia del actualizador antiguo (cam-ui / widget-arena): un archivo suelto en backups_programa
    U3 = pyi_update.Updater(os.path.join(inst, 'hola.py'))
    old = os.path.join(U3.backups_dir, 'hola.pack1.20260101-000000.py')
    open(old, 'w', encoding='utf-8').write('APP_VERSION = "0.9"\n')
    st = U3.state()
    st.pop('last_backup_set', None)
    st['last_backup'] = old
    U3.save_state()
    ok(U3.backup_available(), 'reconoce la copia del formato antiguo')
    U3.rollback()
    ok(open(os.path.join(inst, 'hola.py'), encoding='utf-8').read() == 'APP_VERSION = "0.9"\n', 'vuelve atras desde el formato antiguo')

    # seguridad: huella que no coincide, direccion de otro sitio
    info = json.load(open(os.path.join(site, 'dl', 'update.json')))
    info['files']['hola.py']['sha256'] = '0' * 64
    try:
        U3.apply(info)
        ok(False, 'deberia rechazar una huella que no coincide')
    except pyi_update.UpdateError:
        ok(True, 'rechaza una huella que no coincide (sin tocar nada)')
    ok(open(os.path.join(inst, 'hola.py'), encoding='utf-8').read() == 'APP_VERSION = "0.9"\n', 'nada tocado tras el rechazo')
    try:
        U3._get('https://otro.example/x', 10)
        ok(False, 'deberia rechazar otra direccion')
    except pyi_update.UpdateError:
        ok(True, 'rechaza direcciones de otro sitio')
    info = json.load(open(os.path.join(site, 'dl', 'update.json')))
    info['files']['../fuera.py'] = info['files']['hola.py']
    try:
        U3.apply(info)
        ok(False, 'deberia rechazar rutas fuera de la carpeta')
    except pyi_update.UpdateError:
        ok(True, 'rechaza rutas fuera de la carpeta del programa')

    # sin instalar (codigo fuente): desactivado
    ok(not pyi_update.Updater(os.path.join(app, 'hola.py')).enabled, 'desde el codigo fuente no se actualiza solo')
    srv.shutdown()
    shutil.rmtree(tmp, ignore_errors=True)
    print('TODO OK')


if __name__ == '__main__':
    main()

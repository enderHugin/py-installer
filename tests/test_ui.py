# test_ui.py
"""Pruebas de la ventana y el comportamiento comunes (tkinter y, si esta PySide6, Qt).
Uso: xvfb-run -a python tests/test_ui.py   (o QT_QPA_PLATFORM=offscreen para la parte de Qt)"""
import os
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import pyi_update as P  # noqa: E402

fails = []


def ok(cond, msg):
    print(('ok - ' if cond else 'FALLO - ') + msg)
    if not cond:
        fails.append(msg)


class FakeUpdater(P.Updater):
    """Un Updater de verdad (preferencias, etiquetas...) pero sin red: check/apply simulados."""
    def __init__(self, d, newer=True):
        f = os.path.join(d, 'app.py')
        open(f, 'w').write('x = 1\n')
        super().__init__(f, pack=10, base='https://example.invalid/dl/', state_path=os.path.join(d, 'st.json'),
                         backups_dir=os.path.join(d, 'b'))
        self.newer, self.applied, self.restarts = newer, 0, 0

    def check(self):
        info = {'pack': 11 if self.newer else 10, 'version': '1.1', 'notes': 'Novedad X', 'files': {}}
        return {'ok': True, 'state': 'newer' if self.newer else 'same', 'info': info, 'local': self.local_info()}

    def apply(self, info):
        self.applied += 1
        return {'backup': None}

    def spawn_restart(self, delay=3, argv=None):
        self.restarts += 1


def pump_tk(root, ms):
    end = time.time() + ms / 1000.0
    while time.time() < end:
        root.update()
        time.sleep(0.01)


ok(P.PYI_VERSION == open(os.path.join(os.path.dirname(HERE), 'VERSION')).read().strip(),
   'PYI_VERSION coincide con VERSION (%s)' % P.PYI_VERSION)

# ---------------------------------------------------------------- preferencias antiguas
d = tempfile.mkdtemp()
open(os.path.join(d, 'st.json'), 'w').write('{"watch": true, "auto_install": true}')
u = FakeUpdater(d)
ok(u.state().get('silent_watch') is True and u.state().get('auto_apply') is True,
   'las preferencias antiguas de widget-arena (watch, auto_install) se entienden')
ok(u.auto_try_ok({'pack': 11}) and not u.auto_try_ok({'pack': 11}) and u.auto_try_ok({'pack': 12}),
   'instalar sola: una sola vez por version publicada')
u.mark_auto_notice({'pack': 10})
ok(u.pop_auto_notice() == 'pack 10' and u.pop_auto_notice() is None, 'aviso de "se ha actualizado solo" una vez')

# ---------------------------------------------------------------- tkinter
import tkinter as tk  # noqa: E402
root = tk.Tk()
e = tk.Entry(root)
e.pack()
pump_tk(root, 50)
e.focus_force()
d = tempfile.mkdtemp()
u = FakeUpdater(d)
closed = []
notes = []
ctl = P.tk_install(root, u, 'Prueba', on_close=lambda: closed.append(1), notify=notes.append,
                   startup_delay_ms=10 ** 8, watch_every_ms=10 ** 8)
e.event_generate('<Control-Shift-Alt-F12>')
pump_tk(root, 50)
w = ctl.win
ok(w is not None and w.alive() and w.watch_visible(), 'tk: el atajo desde la ventana principal abre Actualizaciones con la casilla')
txt = []


def walk(x):
    for c in x.winfo_children():
        try:
            txt.append(str(c.cget('text')))
        except Exception:
            pass
        walk(c)


walk(w.top)
ok(any(('py-installer ' + P.PYI_VERSION) in t for t in txt), 'tk: la ventana muestra la version del actualizador')
ok(any('pack 10' in t for t in txt), 'tk: muestra la version instalada')
w.v['watch'].set(True)
w.toggled_watch(True)
ok(u.state().get('silent_watch') is True, 'tk: marcar "vigilar sola" lo guarda')
w.start_check()
pump_tk(root, 400)
ok('pack 11' in w.status.cget('text') and 'Novedad X' in w.notes.get('1.0', 'end'), 'tk: buscar muestra la nueva y sus novedades')
ok(u.applied == 0, 'tk: buscar a mano no instala sin preguntar')
w.apply()
pump_tk(root, 1500)
ok(u.applied == 1 and u.restarts == 1 and closed, 'tk: Actualizar instala y reinicia')
# vigilar sola: instala y reinicia, pero espera si el programa esta ocupado
d = tempfile.mkdtemp()
u2 = FakeUpdater(d)
u2.set_silent_watch(True)
busy = [True]
closed2 = []
ctl2 = P.tk_install(root, u2, 'Prueba2', on_close=lambda: closed2.append(1), busy=lambda: busy[0],
                    startup_delay_ms=10 ** 8, watch_every_ms=10 ** 8)
busy[0] = False
ctl2._probe(startup=False)
busy[0] = True
pump_tk(root, 700)
ok(u2.applied == 1 and u2.restarts == 0, 'tk: vigilar sola instala, pero no reinicia mientras el programa esta ocupado')
busy[0] = False
ctl2.restart_when_idle()
pump_tk(root, 100)
ok(u2.restarts == 1 and closed2 and u2.state().get('auto_notice') == 'pack 11', 'tk: y reinicia en cuanto queda libre')
root.destroy()

# ---------------------------------------------------------------- Qt
try:
    from PySide6 import QtCore, QtWidgets, QtTest
except ImportError:
    QtWidgets = None
    print('(sin PySide6: no se prueba la parte de Qt)')
if QtWidgets:
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    main = QtWidgets.QLineEdit()
    main.show()

    def pump_qt(ms):
        end = time.time() + ms / 1000.0
        while time.time() < end:
            app.processEvents()
            time.sleep(0.01)
    d = tempfile.mkdtemp()
    u = FakeUpdater(d)
    closed = []
    ctl = P.qt_install('PruebaQt', u, on_close=lambda: closed.append(1), parent=None,
                       startup_delay_ms=10 ** 8, watch_every_ms=10 ** 8)
    pump_qt(50)
    M = QtCore.Qt.KeyboardModifier
    QtTest.QTest.keyClick(main, QtCore.Qt.Key.Key_F12, M.ControlModifier | M.ShiftModifier | M.AltModifier)
    pump_qt(100)
    w = ctl.win
    ok(w is not None and w.alive() and w.watch_visible(), 'Qt: el atajo desde otra ventana abre Actualizaciones con la casilla')
    labels = [x.text() for x in w.top.findChildren(QtWidgets.QLabel)]
    ok(any(('py-installer ' + P.PYI_VERSION) in t for t in labels), 'Qt: la ventana muestra la version del actualizador')
    w.c['watch'].setChecked(True)
    ok(u.state().get('silent_watch') is True, 'Qt: marcar "vigilar sola" lo guarda')
    w.c['watch'].setChecked(False)
    ok(not w.watch_visible() and not u.state().get('silent_watch'), 'Qt: desmarcarla la vuelve a esconder')
    w.start_check()
    pump_qt(400)
    ok('pack 11' in w.status.text() and 'Novedad X' in w.notes.toPlainText(), 'Qt: buscar muestra la nueva y sus novedades')
    w.apply()
    pump_qt(1500)
    ok(u.applied == 1 and u.restarts == 1 and closed, 'Qt: Actualizar instala y reinicia')
    w.top.close()
    pump_qt(50)
    ok(not w.alive(), 'Qt: cerrar la ventana')

print('TODO OK' if not fails else '%d FALLOS' % len(fails))
sys.exit(1 if fails else 0)

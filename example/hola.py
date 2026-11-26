# hola.py
"""Programa de ejemplo de py-installer: una ventana de tkinter que dice hola, en el idioma que
eligio el instalador (lang.json) y con el menu Idioma de lang-kit. Sus textos estan en lang/*.json.
Con --check solo comprueba que arranca y saluda en su idioma (lo usan las pruebas automaticas)."""
import json
import os
import sys
import tkinter as tk

APP_VERSION = "1.0.0"

HERE = os.path.dirname(os.path.abspath(__file__))


def info():
    try:
        return json.load(open(os.path.join(HERE, 'install_info.json'), encoding='utf-8'))
    except OSError:
        return {}


def textos():
    """lang-kit: lo instala py-installer junto al programa. Desde el codigo fuente, sin el, en espanol."""
    try:
        import langkit
        return langkit.init(__file__)
    except ImportError:
        return None


def main():
    L = textos()
    t = L.t if L else (lambda k, **v: {'hola.greeting': '¡Hola! Instalado con py-installer.'}.get(k, k))
    if '--check' in sys.argv:
        print('hola', APP_VERSION, sys.version.split()[0], L.code if L else '-', t('hola.greeting'))
        return
    root = tk.Tk()
    root.title(t('hola.title'))
    root.geometry('380x200')
    if L:
        bar = tk.Menu(root)
        import langkit
        langkit.tk_menu(bar, L, restart=lambda: (langkit.restart_program(), root.destroy()))
        root.config(menu=bar)
    tk.Label(root, text=t('hola.greeting'), font=('', 14)).pack(pady=(28, 6))
    i = info()
    tk.Label(root, text=t('hola.version', v=APP_VERSION, py=sys.version.split()[0]), fg='#666').pack()
    if i.get('program_dir'):
        tk.Label(root, text=i['program_dir'], fg='#999', font=('', 9)).pack(pady=(6, 0))
    # actualizaciones: aviso al abrir, "sin preguntar", ventana para revisar y Ctrl+Shift+Alt+F12 en ella
    try:
        import pyi_update
        upd = pyi_update.tk_install(root, pyi_update.Updater(__file__, version=APP_VERSION), 'Hola py-installer')
        tk.Button(root, text=t('common.check_updates'), command=upd.show).pack(pady=8)
    except ImportError:
        pass                     # desde el codigo fuente (sin instalar) no hay actualizador
    root.mainloop()


if __name__ == '__main__':
    main()

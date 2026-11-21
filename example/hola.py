# hola.py
"""Programa de ejemplo de py-installer: una ventana de tkinter que dice hola.
Con --check solo comprueba que arranca (lo usan las pruebas automaticas)."""
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


def main():
    if '--check' in sys.argv:
        print('hola', APP_VERSION, sys.version.split()[0])
        return
    root = tk.Tk()
    root.title('Hola (py-installer)')
    root.geometry('360x160')
    tk.Label(root, text='¡Hola! Instalado con py-installer.', font=('', 14)).pack(pady=(28, 6))
    i = info()
    tk.Label(root, text=f'version {APP_VERSION} · Python {sys.version.split()[0]}', fg='#666').pack()
    if i.get('program_dir'):
        tk.Label(root, text=i['program_dir'], fg='#999', font=('', 9)).pack(pady=(6, 0))
    root.mainloop()


if __name__ == '__main__':
    main()

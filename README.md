<!-- README.md -->
# py-installer

**Convierte cualquier programa de Python en una app que se instala con un clic en Windows, Linux y macOS.**

Es el sistema de instalación de [widget-arena](https://github.com/enderHugin/widget-arena) y [cam-ui](https://github.com/enderHugin/cam-ui), sacado a un repo propio para mantenerlo en un solo sitio. Cada programa solo tiene que describirse en un `py-installer.toml`. py-installer genera:

- **Instaladores** para cada sistema, con el nombre del proyecto: `<id>-instalar.cmd` (Windows), `<id>-instalar.sh` (Linux) y `<id>-instalar-macos.zip` (macOS).
  - No piden administrador ni Python instalado: consiguen su propio Python con [uv](https://github.com/astral-sh/uv) y no tocan el que tengas.
  - Todo se instala solo para tu usuario, con accesos directos e icono. En Windows además aparece en *Aplicaciones instaladas*.
  - Traen desinstalador, guardan un registro de la instalación y comprueban al final que las librerías cargan.
  - Volver a ejecutar un instalador actualiza el programa sin pisar tus datos.
- **Una página de descarga** que detecta tu sistema, o tu propia página con los enlaces ya rellenos.
- **`update.json`** con la versión, las huellas sha256 y las novedades, para que el programa pueda actualizarse solo.
- **En el idioma de quien lo descarga** (español, inglés y catalán, con [lang-kit](https://github.com/enderHugin/lang-kit)): la página ofrece el instalador en el idioma del navegador y el programa queda en ese idioma.
- **Solo los sistemas que elijas.** Si un programa aún no funciona en macOS, no se genera su instalador y la página dice «aún no disponible».

## Usarlo en un programa

1. En la carpeta del programa:
   ```bash
   python3 path/to/py-installer/pyi.py init .
   ```
   Crea `py-installer.toml`, `VERSION` y `.github/workflows/pages.yml`. Revisa el manifiesto: lo mínimo es `id`, `name` y `entry`.
2. En GitHub: **Settings → Pages → Source: GitHub Actions**.
3. Haz push a `main`. La página queda en `https://<usuario>.github.io/<repo>/` y los instaladores en `…/dl/`.

El workflow del programa se reduce a esto (el resto es la publicación estándar de Pages):

```yaml
- uses: actions/checkout@v4
- uses: enderHugin/py-installer@v1
- uses: actions/upload-pages-artifact@v3
  with: { path: _site }
```

`@v1` es una etiqueta que avanza con cada arreglo compatible. Al publicar un arreglo del instalador, todos los programas lo recogen en su siguiente publicación. Un cambio incompatible sería `@v2` y cada programa decide cuándo pasarse.

## El manifiesto

Ejemplo comentado con todas las opciones: [`templates/py-installer.toml`](templates/py-installer.toml). Un programa de tkinter sencillo:

```toml
[app]
id = "md-reader"
name = "MD Reader"
entry = "md_reader.py"
description = "Lee y edita Markdown"
# os = ["windows", "linux"]      # por defecto, los tres

[icon]
png = "assets/icon.png"          # el .ico y el .icns se generan solos

[deps]
required = ["markdown"]
```

| Sección | Para qué |
|---|---|
| `[app]` | id, nombre, archivo principal, otros archivos (`files`), `gui`, versión de Python, sistemas (`os`), carpeta, nombre de la carpeta del entorno (`venv`), acceso en el escritorio, `updater` |
| `[icon]` | `png` (basta con este), `ico`, `icns` |
| `[deps]` | `required` (si fallan, se para), `requirements` (un requirements.txt), `optional` (si fallan, solo avisa y dice por qué) |
| `[check]` | código que debe funcionar al final (`import numpy, PIL, tkinter`…) y su entorno (`QT_QPA_PLATFORM`…) |
| `[data]` | carpeta de datos iniciales (se copian sin pisar lo existente) y qué conservar al desinstalar |
| `[[extra]]` | descargas aparte por sistema, como ffmpeg en Windows (zip o tar.gz; solo se baja si falta) |
| `[hooks]` | `post_install`: un .py propio que se ejecuta tras instalar (p. ej. librerías del sistema que necesita Qt) |
| `[[associate]]` | tipos de archivo que abre el programa (ver abajo) |
| `[site]` | carpeta de tu propia página y nombres de los instaladores publicados |
| `[i18n]` | idiomas (`languages`, por defecto todos los que tiene py-installer), idioma original (`source`, `"es"`) y traducciones de los textos del manifiesto (ver abajo) |

La versión sale del archivo `VERSION`, o de `APP_VERSION = "x.y.z"` en el programa. Si existen los dos, tienen que coincidir. Si el programa define `APP_PACK = N`, se incluye en `update.json`.

## Tipos de archivo

```toml
[[associate]]
ext = [".md", ".markdown"]
description = "Documento Markdown"
# role = "viewer"            # por defecto "editor"
# mime = "text/markdown"     # Linux; por defecto, el conocido o uno propio del programa
```

El instalador hace que el programa los abra. El programa recibe la ruta del archivo como primer argumento. En macOS la recibe con `::tk::mac::OpenDocument`, si es de tkinter.

- **Windows**:
  - El programa aparece en «Abrir con», con su nombre y su icono.
  - Si ningún otro programa abre ese tipo (por ejemplo, un `.wapack` propio), queda como el de siempre y el doble clic lo abre.
  - Si ya hay otro elegido (un `.md` con el Bloc de notas), Windows no deja cambiarlo sin el usuario. El instalador explica al final cómo hacerlo: clic derecho ▸ Abrir con ▸ Elegir otra aplicación ▸ «Usar siempre».
- **Linux**: los tipos propios se registran (`~/.local/share/mime`) y el doble clic los abre. Los conocidos, como `text/markdown`, solo se añaden a «Abrir con».
- **macOS**: la `.app` declara los tipos (`CFBundleDocumentTypes`) y se registra en LaunchServices.
- **Desinstalar** lo deja todo como estaba.

## Idiomas

py-installer usa [lang-kit](https://github.com/enderHugin/lang-kit), el sistema de idiomas común. Sus propios textos están en `lang/pyi.<idioma>.json`: los del instalador, el desinstalador, la página de descarga y la ventana de Actualizaciones. Ahora mismo hay español, inglés y catalán.

**Un instalador por idioma.** En Windows se publican estos instaladores:
- `<id>-instalar.cmd` en el idioma original;
- `<id>-instalar-en.cmd` y `<id>-instalar-ca.cmd` para los demás idiomas.

Linux y macOS de momento tienen un solo instalador, en español.

**La página elige el instalador según el idioma de quien la visita.** Mira, en este orden:
1. `?lang=xx` en la dirección;
2. el idioma que eligió antes en la página;
3. el de su navegador.

La página generada trae también un selector de idioma. En una página propia, py-installer añade `dl/pyi-lang.js` a cada página que enlaza un instalador. Ese script cambia los enlaces de descarga por los del idioma del visitante. Para no añadirlo: `page_script = false` en `[i18n]`.

**Lo que queda instalado.** Junto al programa quedan:
- `langkit.py`;
- `lang/` con todos los diccionarios: los del programa (`lang/*.json` de su repo), los de py-installer y los comunes;
- `lang.json` con el idioma del instalador.

Reinstalar o actualizar no cambia `lang.json`, así que se conserva el idioma que eligió el usuario en el menú «Idioma» del programa. Al desinstalar sin borrar datos, `lang.json` también se conserva. Los diccionarios viajan en `update.json` como un archivo más, de modo que las instalaciones antiguas los reciben con la siguiente actualización.

**En el programa:**

```python
import langkit
L = langkit.init(__file__)
from langkit import t
menu.add_command(label=t('menu.open'), ...)
langkit.tk_menu(menubar)          # o langkit.qt_menu(...)
```

El ejemplo completo está en `example/hola.py`, y cómo pasar un programa a varios idiomas, en el README de lang-kit. Sin `lang/` propio, el programa sigue en español, pero la ventana de Actualizaciones ya sale en su idioma.

**Textos del manifiesto.** La descripción, los tipos de archivo, los motivos de los opcionales y las etiquetas de las descargas extra se traducen así:

```toml
[i18n.en]
"Lee y edita Markdown" = "Read and edit Markdown"
"Documento Markdown" = "Markdown document"
```

**Otro idioma para el instalador:** añade `lang/pyi.<idioma>.json` aquí, con las mismas claves que `pyi.es.json`. `tests/test_i18n.py` comprueba que no falte ninguna y que cada texto lleve sus variables.

## Qué deja instalado

| | Programa | Datos del instalador (uv, Python, registro, desinstalador) |
|---|---|---|
| Windows | `%LOCALAPPDATA%\Programs\<folder>` | `%LOCALAPPDATA%\<folder>` |
| Linux | `~/.local/share/<folder>/app` | `~/.local/share/<folder>` |
| macOS | `~/Library/Application Support/<folder>/app` | `~/Library/Application Support/<folder>` |

Junto al programa quedan:
- `.venv`, su entorno de Python;
- `install_info.json`, con la versión, la URL de origen, las rutas y el idioma del instalador, por si el programa lo necesita para actualizarse;
- `lang.json`, `langkit.py` y `lang/` (ver *Idiomas*).

**Variables opcionales** (`<PREFIJO>` = `id` en mayúsculas con `_`, o `env_prefix`):

- `<PREFIJO>_INSTALL_DIR`: otra carpeta u otra unidad (solo Windows).
- `<PREFIJO>_NO_LAUNCH=1`: no abrir el programa al terminar ni mostrar ventanas.
- `<PREFIJO>_BASE_URL`: descargar de otro sitio (para pruebas).
- `<PREFIJO>_UV` y `<PREFIJO>_PYTHON`: usar un uv o un Python ya existentes (solo Linux y macOS).

**Desinstalar sin preguntas:**

- Windows: `uninstall.ps1 -Si [-BorrarDatos]`, o el instalador con `desinstalar -Si`.
- Linux y macOS: `uninstall.sh --si [--borrar-datos]`.

## Actualizaciones dentro del programa

py-installer instala `pyi_update.py` junto a cada programa y lo publica en `update.json`, así que se actualiza solo como el resto de archivos. Si un programa no lo quiere, basta con poner `updater = false` en `[app]`.

**Qué hace:**
- Compara la versión instalada con la publicada, por pack o por versión.
- Descarga solo de la web del programa: no sigue redirecciones a otros sitios.
- Comprueba el tamaño y la huella sha256 de cada archivo, y que los .py compilan, antes de tocar nada.
- Antes de actualizar, guarda una copia de lo que cambia (se conservan las 5 últimas). Desde ahí se puede volver atrás, incluso desde las copias del actualizador antiguo de cam-ui y widget-arena.
- Actualiza también los archivos nuevos que se añadan, y reinicia el programa.

**Su propia versión.** El instalador y el actualizador comparten un número de versión, el de py-installer (`VERSION`, ahora 1.4.0; en el código, `pyi_update.PYI_VERSION`). Va aparte de la versión de cada programa. Sale abajo en la ventana de Actualizaciones («Actualizador py-installer 1.4.0»), en `update.json` (`"updater"`) y en `install_info.json`. El actualizador llega a cada programa cuando ese programa publica una versión nueva.

**La misma ventana y el mismo comportamiento en todos los programas**, en tkinter (`tk_install`) y en Qt (`qt_install`):
- Al abrir, mira si hay versión nueva y pregunta. Si se marcó «sin preguntar», la instala sola.
- Con «vigilar sola», mira cada rato mientras el programa está abierto, instala y reinicia sin decir nada.
- Instalar sola se intenta una vez por versión publicada, así que no puede quedarse en un bucle de reinicios. Al volver a abrir, avisa de a qué versión se actualizó.
- No reinicia mientras el programa está ocupado (`busy`, por ejemplo grabando), ni en mitad de un arrastre o con un menú o diálogo abierto.
- El **atajo secreto Ctrl+Shift+Alt+F12** (con o sin Win) lo recibe el actualizador, desde cualquier ventana del programa. Abre Actualizaciones con la casilla oculta «Vigilar sola, sin avisos» a la vista.

**Preferencias**, guardadas en `actualizacion.json`:

| | |
|---|---|
| `auto` | avisar al abrir si hay versión nueva (por defecto, sí) |
| `auto_apply` | actualizar al abrir **sin preguntar** y reiniciar |
| `silent_watch` | **«vigilar sola, sin avisos»**: la casilla oculta del atajo secreto |

También se entienden los nombres antiguos de widget-arena (`watch` y `auto_install`).

**tkinter:**

```python
try:
    import pyi_update
    upd = pyi_update.tk_install(root, pyi_update.Updater(__file__, version=APP_VERSION), 'Mi App',
                                on_close=guardar_y_salir, busy=lambda: grabando, notify=barra_de_estado)
    menu.add_command(label='Buscar actualizaciones…', command=upd.show)
except ImportError:
    pass          # ejecutado desde el código fuente: sin actualizador
```

**Qt** (PySide6, PyQt6 o PyQt5), con la `QApplication` ya creada:

```python
upd = pyi_update.qt_install('Mi App', pyi_update.Updater(__file__, pack=APP_PACK), on_close=salir,
                            parent=ventana, busy=lambda: grabando, notify=aviso)
accion.triggered.connect(lambda: upd.show())
```

**Con otra interfaz** se usa solo el motor: `Updater.check()`, `apply(info)`, `rollback()`, `spawn_restart()` y las preferencias.

**Desde una terminal:** `python pyi_update.py programa.py [check|apply|rollback]`.

## Probar en local

```bash
python3 pyi.py build --app example --base http://127.0.0.1:8765 --out _site
(cd _site && python3 -m http.server 8765) &
HOLA_PYI_NO_LAUNCH=1 bash _site/dl/hola-pyi-instalar.sh
```

En cada push, [`test.yml`](.github/workflows/test.yml) instala de verdad el programa de [`example/`](example) en Windows, Linux y macOS. Después lo reinstala, comprueba que los datos siguen ahí y lo desinstala.

## Pasar widget-arena y cam-ui a py-installer

Queda pendiente; se hará programa por programa:

- **cam-ui**:
  - `os = ["windows"]` hasta que haya Linux y macOS.
  - `optional` para pystray, pyvirtualcam, cryptography y qrcode.
  - `[[extra]]` para ffmpeg y `keep` con `config.json` y `Capturas`.
  - `folder = "cam-ui"` y `env_prefix = "CAMUI"` para conservar rutas y variables.
- **widget-arena**:
  - `files = ["herramientas.py"]` y `[data] zip = "defaults"`.
  - `[check]` con PySide6 y `QT_QPA_PLATFORM = "offscreen"`.
  - `post_install` con su comprobación de librerías del sistema para Qt.
  - `folder = "WidgetArena"`.
  - Su página propia sigue funcionando: `__BASE_URL__`, `__VERSION__`, `__PACK__` y `__REPO_URL__` se sustituyen igual que ahora.

Los dos ya leen `dl/update.json` con el mismo formato, así que su actualizador no cambia.

## Licencia

MIT

<!-- README.md -->
# py-installer

**Convierte cualquier programa de Python en una app que se instala con un clic en Windows, Linux y macOS.**

Es el sistema de instalación de [widget-arena](https://github.com/enderHugin/widget-arena) y [cam-ui](https://github.com/enderHugin/cam-ui), sacado a un repo propio para mantenerlo en un solo sitio. Cada programa solo tiene que describirse en un `py-installer.toml`. py-installer genera:

- **Instaladores** para cada sistema: `install-windows.cmd`, `install-linux.sh` e `install-macos.zip`.
  - No piden administrador ni Python instalado: consiguen su propio Python con [uv](https://github.com/astral-sh/uv) y no tocan el que tengas.
  - Todo se instala solo para tu usuario, con accesos directos e icono. En Windows además aparece en *Aplicaciones instaladas*.
  - Traen desinstalador, guardan un registro de la instalación y comprueban al final que las librerías cargan.
  - Volver a ejecutar un instalador actualiza el programa sin pisar tus datos.
- **Una página de descarga** que detecta tu sistema, o tu propia página con los enlaces ya rellenos.
- **`update.json`** con la versión, las huellas sha256 y las novedades, para que el programa pueda actualizarse solo.
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
| `[app]` | id, nombre, archivo principal, otros archivos (`files`), `gui`, versión de Python, sistemas (`os`), carpeta, acceso en el escritorio |
| `[icon]` | `png` (basta con este), `ico`, `icns` |
| `[deps]` | `required` (si fallan, se para), `requirements` (un requirements.txt), `optional` (si fallan, solo avisa y dice por qué) |
| `[check]` | código que debe funcionar al final (`import numpy, PIL, tkinter`…) y su entorno (`QT_QPA_PLATFORM`…) |
| `[data]` | carpeta de datos iniciales (se copian sin pisar lo existente) y qué conservar al desinstalar |
| `[[extra]]` | descargas aparte por sistema, como ffmpeg en Windows (zip o tar.gz; solo se baja si falta) |
| `[hooks]` | `post_install`: un .py propio que se ejecuta tras instalar (p. ej. librerías del sistema que necesita Qt) |
| `[site]` | carpeta de tu propia página y nombres de los instaladores publicados |

La versión sale del archivo `VERSION`, o de `APP_VERSION = "x.y.z"` en el programa. Si existen los dos, tienen que coincidir. Si el programa define `APP_PACK = N`, se incluye en `update.json`.

## Qué deja instalado

| | Programa | Datos del instalador (uv, Python, registro, desinstalador) |
|---|---|---|
| Windows | `%LOCALAPPDATA%\Programs\<folder>` | `%LOCALAPPDATA%\<folder>` |
| Linux | `~/.local/share/<folder>/app` | `~/.local/share/<folder>` |
| macOS | `~/Library/Application Support/<folder>/app` | `~/Library/Application Support/<folder>` |

Junto al programa queda `.venv` (su entorno de Python) e `install_info.json`, con la versión, la URL de origen y las rutas, por si el programa lo necesita para actualizarse.

**Variables opcionales** (`<PREFIJO>` = `id` en mayúsculas con `_`, o `env_prefix`):

- `<PREFIJO>_INSTALL_DIR`: otra carpeta u otra unidad (solo Windows).
- `<PREFIJO>_NO_LAUNCH=1`: no abrir el programa al terminar ni mostrar ventanas.
- `<PREFIJO>_BASE_URL`: descargar de otro sitio (para pruebas).
- `<PREFIJO>_UV` y `<PREFIJO>_PYTHON`: usar un uv o un Python ya existentes (solo Linux y macOS).

**Desinstalar sin preguntas:**

- Windows: `uninstall.ps1 -Si [-BorrarDatos]`, o el instalador con `desinstalar -Si`.
- Linux y macOS: `uninstall.sh --si [--borrar-datos]`.

## Probar en local

```bash
python3 pyi.py build --app example --base http://127.0.0.1:8765 --out _site
(cd _site && python3 -m http.server 8765) &
HOLA_PYI_NO_LAUNCH=1 bash _site/dl/install-linux.sh
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

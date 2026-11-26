<!-- README.md -->
# lang-kit (copia)

Copia de [lang-kit](https://github.com/enderHugin/lang-kit), el sistema de idiomas común. py-installer instala `langkit.py` y los diccionarios comunes (`lang/common.<idioma>.json`) junto a cada programa.

**No se edita aquí.** Para cambiarlo, se cambia en lang-kit y se copia de nuevo:

```bash
cp ../lang-kit/langkit.py ../lang-kit/VERSION vendor/lang-kit/ && cp ../lang-kit/lang/common.*.json vendor/lang-kit/lang/
```

`tests/test_i18n.py` comprueba que `VERSION` coincide con `LANGKIT_VERSION` de `langkit.py`.

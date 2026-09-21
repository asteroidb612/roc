# roc-visidata (the Python package)

`pip install roc-visidata`, then in `~/.visidatarc`:

```python
import visidata_roc
```

See [../README.md](../README.md) for what it does and how to write a plugin.

## The engine

The package needs `libroc_vd_engine.so` — the Roc compiler, the engine and the
host in one file (~55 MB). A wheel carries it beside the package. From a source
checkout, build it once with `../engine/build.sh` and it is found automatically;
`options.roc_engine` or `$ROC_VD_ENGINE` override where to look.

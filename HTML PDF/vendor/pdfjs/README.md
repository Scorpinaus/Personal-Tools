# Local PDF.js Assets

The app does not download PDF.js, load it from a CDN, or install packages.
It uses the locally supplied PDF.js distribution in this folder.

Current expected layout:

- `pdfjs-5.7.284-dist/build/pdf.mjs`
- `pdfjs-5.7.284-dist/build/pdf.worker.mjs`
- `pdfjs-5.7.284-dist/web/cmaps/`
- `pdfjs-5.7.284-dist/web/standard_fonts/`
- `pdfjs-5.7.284-dist/web/wasm/`

The reader imports the build module and configures the worker from those local
paths. The `web/` asset folders are used for broader PDF compatibility.

Because PDF.js 5 uses JavaScript modules and a worker, some browsers will block
it when `index.html` is opened directly with `file://`. If that happens, serve
the project folder locally, for example at `http://localhost`, without adding
any downloaded dependencies.

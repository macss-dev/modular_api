/**
 * Docs UI handler — serves the `@macss/docs-ui` widget from CDN.
 *
 * Loads `@macss/docs-ui` from jsdelivr CDN, which wraps Swagger UI with
 * system-aware dark mode.  The local `/openapi.json` endpoint provides
 * the spec.  Styling, dark mode, and Swagger UI loading are handled
 * entirely by docs-ui — no inline CSS or JS in this template.
 *
 * See: https://github.com/macss-dev/modular_api/tree/main/code/docs-ui
 */

import type { RequestHandler } from 'express';

const DOCS_UI_CDN = 'https://cdn.jsdelivr.net/npm/@macss/docs-ui@0.1/dist';

const DOCS_UI_HTML_TEMPLATE = `<!DOCTYPE html>
<html>
  <head>
    <title>{{title}} — API Reference</title>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
  </head>
  <body>
    <div id="swagger-ui"></div>
    <script src="${DOCS_UI_CDN}/docs-ui.js"></script>
    <script>DocsUI.init({ specUrl: "{{specUrl}}" })</script>
  </body>
</html>`;

export function buildSwaggerDocsHtml(options: { title: string; specUrl?: string }): string {
  return DOCS_UI_HTML_TEMPLATE.replace('{{title}}', options.title).replace(
    '{{specUrl}}',
    options.specUrl ?? '/openapi.json',
  );
}

/**
 * Returns an Express handler that serves the docs-ui HTML.
 *
 * Usage:
 * ```ts
 * app.get('/docs', swaggerDocsHandler({ title: 'My API' }));
 * ```
 */
export function swaggerDocsHandler(options: { title: string }): RequestHandler {
  const html = buildSwaggerDocsHtml(options);

  return (_req, res) => {
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    res.send(html);
  };
}

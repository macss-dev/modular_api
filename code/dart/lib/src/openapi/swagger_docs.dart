/// Docs UI handler — serves the `@macss/docs-ui` widget from CDN.
///
/// Loads `@macss/docs-ui` from jsdelivr CDN, which wraps Swagger UI with
/// system-aware dark mode.  The local `/openapi.json` endpoint provides
/// the spec.  Styling, dark mode, and Swagger UI loading are handled
/// entirely by docs-ui — no inline CSS or JS in this template.
///
/// See: https://github.com/macss-dev/modular_api/tree/main/code/docs-ui
library;

import 'package:shelf/shelf.dart';

const _docsUiCdn = 'https://cdn.jsdelivr.net/npm/@macss/docs-ui@0.1/dist';

const _docsUiHtmlTemplate = '''
<!DOCTYPE html>
<html>
  <head>
    <title>{{title}} — API Reference</title>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
  </head>
  <body>
    <div id="swagger-ui"></div>
    <script src="$_docsUiCdn/docs-ui.js"></script>
    <script>DocsUI.init({ specUrl: "{{specUrl}}" })</script>
  </body>
</html>''';

String buildSwaggerDocsHtml({
  required String title,
  String specUrl = '/openapi.json',
}) {
  return _docsUiHtmlTemplate
      .replaceFirst('{{title}}', title)
      .replaceFirst('{{specUrl}}', specUrl);
}

/// Returns a Shelf [Handler] that serves the docs-ui HTML.
///
/// ```dart
/// router.get('/docs', swaggerDocsHandler(title: 'My API'));
/// ```
Handler swaggerDocsHandler({required String title}) {
  final html = buildSwaggerDocsHtml(title: title);

  return (Request request) {
    return Response.ok(
      html,
      headers: {'content-type': 'text/html; charset=utf-8'},
    );
  };
}

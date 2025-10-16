[![pub package](https://img.shields.io/pub/v/modular_api.svg)](https://pub.dev/packages/modular_api)

# modular_api

Use-case–centric toolkit for building Modular APIs with Shelf.
Define `UseCase` classes (input → validate → execute → output), connect them to HTTP routes,
add CORS / API Key middlewares, and expose Swagger / OpenAPI documentation.

> Designed for the MACSS ecosystem — modular, explicit and testable server code.

---

## ✨ Features

- ✅ `UseCase<I extends Input, O extends Output>` base classes and DTOs (`Input`/`Output`).
- 🧩 `useCaseHttpHandler()` adapter: accepts a factory `UseCase Function(Map<String, dynamic>)`
  and returns a Shelf `Handler`.
- 🧱 Included middlewares:
  - `cors()` — simple CORS support.
  - `apiKey()` — header-based authentication; the key is read from the `API_KEY` environment
    variable (via `Env`).
- 📄 OpenAPI / Swagger helpers:
  - `OpenApi.init(title)` and `OpenApi.docs` — generate an OpenAPI spec from registered
    usecases (uses DTO `toSchema()`), and provide a Swagger UI `Handler`.
- ⚙️ Utilities: `Env.getString`, `Env.getInt`, `Env.setString` (.env support via dotenv).
- 🧪 Example project and tests included in `example/` and `test/`.

- 🗄️ ODBC database client: a minimal ODBC `DbClient` implementation (DSN-based) tested with Oracle and SQL Server — see `NOTICE` for provenance and details.
  
  Usage:

  ```dart
  import 'package:modular_api/modular_api.dart';

  Future<void> runQuery() async {
    // Create a DSN-based client (example factories available in example/lib/db/db.dart)
    final db = createSqlServerClient();

    try {
      final rows = await db.execute('SELECT @@VERSION as version');
      print(rows);
    } finally {
      // ensure disconnect
      await db.disconnect();
    }
  }
  ```

  See `example/lib/db/db_client.dart` for convenience factories and `NOTICE` for provenance details.

---

## 📦 Installation

In `pubspec.yaml`:

```yaml
dependencies:
  modular_api: ^0.0.1
```

Or from the command line:

```powershell
dart pub add modular_api
dart pub get
```

---

## 🚀 Quick start

This quick start mirrors the included example implementation (`example/bin/example.dart`).

```dart
import 'package:modular_api/modular_api.dart';

Future<void> main() async {
  final port = Env.getInt('PORT');

  final api = ModularApi(basePath: '/api');

  // Modules + usecases (the example project registers a HelloWorld usecase)
  api.module('module1', (m) {
    m.usecase('hello-world', HelloWorld.fromJson); // POST by default
  });

  // Middlewares
  api.use(cors());

  await api.serve(
    port: port,
    onBeforeServe: (root) async {
      await OpenApi.init('Example API');
      root.get('/docs', OpenApi.docs);
    },
  );
}
```

Example request (example server registers `/api/module1/hello-world` as a POST):

```bash
curl -H "Content-Type: application/json" -d '{"word":"world"}' \
  -H "x-api-key: SECRET" \
  "http://localhost:8080/api/module1/hello-world"
```

Example response (HelloOutput):

```json
{"output":"Hello, world!"}
```

---

## 🧭 Architecture

* **UseCase layer** — pure logic, independent of HTTP.
* **HTTP adapter** — turns a `UseCase` into a `Handler`.
* **Middlewares** — cross-cutting concerns (CORS, auth, logging).
* **Swagger UI** — documentation served from your YAML definition.

---

## 🧩 Middlewares

```dart
final handler = const Pipeline()
  .addMiddleware(cors())
  .addMiddleware(apiKey())
    .addHandler(router.call);
```

---

## 📄 Swagger/OpenAPI

To auto-generate the spec from registered routes and serve a UI:

```dart
/// mount OpenApi.docs on your router (/docs)
await OpenApi.init('My API');
```

Open `http://localhost:8080/docs` to view the UI.

---

## 🧱 Modular example (`example/` folder)

Check `example/bin/example.dart` and `example/lib/modules/module1/hello_world.dart` for a concrete
`UseCase` + DTO example and a runnable server.

---

## 🧪 Tests

The repository includes example tests (`test/usecase_test.dart`) that demonstrate the
recommended pattern and the `useCaseTestHandler` helper for unit-testing `UseCase` logic.

Run tests with:

```powershell
dart test
```

---

## 🛠️ Compile to executable

* **Windows**

  ```bash
  dart compile exe example/example.dart -o build/api_example.exe
  ```

* **Linux / macOS**

  ```bash
  dart compile exe example/example.dart -o build/api_example
  ```

---

## 📄 License

MIT © [ccisne.dev](https://ccisne.dev)

```
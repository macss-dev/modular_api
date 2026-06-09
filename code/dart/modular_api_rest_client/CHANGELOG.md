# Changelog

## 0.4.8

- replace `dart:io` `HttpClient` with `package:http` for full Flutter web (dart2js) compatibility
- `HttpServiceClient` now works on all Flutter platforms: web, mobile, desktop, and server

## 0.4.7

- bootstrap `modular_api_rest_client` for Dart
- add the first REST client slice with normalized results and failures
- add tests for happy path, decode failures, auth injection, timeout, and HTTP non-2xx normalization
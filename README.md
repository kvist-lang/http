# Kvist HTTP

HTTP server, client, session, SSE, and Datastar helpers for
[Kvist](https://github.com/kvist-lang/kvist).

The locally adapted Odin HTTP implementation is included at
`deps/odin-http`. Place this repository in your project's dependency folder and
import it by relative path:

```clojure
(import http "deps/http")
```

See [the HTTP guide](docs/HTTP.md). Run the tests with:

```sh
kvist test tests/http-tests.kvist
```

---
name: new-api-client
description: Scaffold an external API client in Go projects that use the `internal/adapters/clients/httpx` wrapper pattern (a custom retry + circuit-breaker HTTP client built on top of net/http). Creates a domain interface, an adapter package with functional options, and a compile-time interface-conformance check. Use when adding a third-party API integration to a Go project with this specific httpx pattern — the skill stops with guidance if the pattern isn't present, since the scaffold won't compile without it.
---

# New API Client Workflow

Use this skill when adding a new external API integration to a Go project that uses the `internal/adapters/clients/httpx` wrapper. The skill reads the project's `go.mod` for the module path and produces a domain interface in `internal/domain/<package>/` plus an adapter under `internal/adapters/clients/<name>/`.

For the full annotated example (client.go / types.go / client_test.go), see `references/example-client.md` — Steps 2 and 3 below cover the structural decisions; the reference is the copy-paste template.

## Step 0: Preflight — verify the project uses the httpx pattern

This skill assumes a `httpx.Client` wrapper that provides retry and circuit-breaker behavior. Without it, the generated code won't compile. Before doing anything else:

```bash
ls internal/adapters/clients/httpx/ 2>/dev/null
```

If the directory does not exist, stop and tell the user:

> "This skill scaffolds clients that depend on `internal/adapters/clients/httpx` (a project-specific HTTP wrapper with retry + circuit breaker). I don't see that package in this repo. If your project uses a different HTTP pattern, the scaffold won't compile — I'd need to know what to use instead. Options: (a) tell me the equivalent wrapper to use, (b) point me at an existing client in this codebase to mirror, or (c) skip the skill and write the client by hand."

Also confirm the module path by reading `go.mod` — the generated imports will use this path. If `go.mod` is missing, stop.

## Step 1: Define the domain interface

Create or extend an interface in `internal/domain/<package>/`. The interface lives in domain — no external dependencies.

```go
// internal/domain/myfeature/provider.go
package myfeature

type Provider interface {
    GetData(ctx context.Context, query string) (*Result, error)
    Available() bool
    Name() string
}
```

Required shape:
- First parameter is `context.Context`
- `Available() bool` — for graceful degradation when not configured (callers can check before calling)
- `Name() string` — for logging and diagnostics

## Step 2: Create the adapter package

Create `internal/adapters/clients/<name>/` with this layout:

```
internal/adapters/clients/myapi/
├── client.go      # Client struct, constructor, methods
├── types.go       # API response types (separate from domain types)
└── client_test.go # Tests with httptest.NewServer
```

Key structural decisions (the reference has the code):
- `httpx.Client` is composed in via `NewClient` — gives retry + circuit breaker for free
- Functional options pattern (`Option func(*Client)`) so the constructor signature stays stable as cross-cutting concerns are added (`WithLogger`, `WithBaseURL`, etc.)
- Compile-time interface check: `var _ myfeature.Provider = (*Client)(nil)` — fails loudly if the adapter drifts from the interface
- `Available()` returns `c.apiKey != ""` (or whatever credential the client needs) — empty key produces a no-op client rather than a panic
- Separate `apiResponse` types from domain types — API schema changes don't bleed into the domain layer

See `references/example-client.md` for the complete `client.go`, `types.go`, and `client_test.go` template with all imports and patterns annotated.

## Step 3: Implement the interface methods

Each method follows the same shape: build headers (auth + accept), call `c.httpClient.Get`/`Post`/etc. with a context and timeout, unmarshal into the API-shape type, convert to the domain type, return.

Wrap errors with context that names the client and operation:

```go
if err != nil {
    return nil, fmt.Errorf("myapi get data: %w", err)
}
```

This gives the error chain enough information that the caller can identify which client failed without re-reading the stack.

## Step 4: Add the credential to config

1. Add a config field for the API key/credentials in the project's config types (look for `internal/platform/config/`, `internal/config/`, or wherever the project keeps them — read `CLAUDE.md` or scan for existing API keys to find the convention)
2. Wire `os.Getenv` in the project's config loader
3. Add a default value if the project's config layer supports defaults
4. Add to `.env.example`
5. Add to `CLAUDE.md` Environment Variables section

## Step 5: Wire it into main

In the project's main wiring file (commonly `cmd/<app>/init.go` or `main.go`):

```go
myClient := myapi.NewClient(cfg.Adapters.MyAPIKey, myapi.WithLogger(logger))
```

Inject into consuming services via their own functional options:

```go
serviceOpts = append(serviceOpts, campaigns.WithMyProvider(myClient))
```

## Step 6: Write tests

Use `httptest.NewServer` to mock the external API — point the client at the test server with `WithBaseURL`. The reference has a complete test file showing the pattern, including how to assert on the request path and headers the client sends.

If the API has rate limits, add a `golang.org/x/time/rate` limiter inside the client and test the rate-limited path.

## Step 7: Update documentation

- Update `CLAUDE.md` Architecture section with the new package
- Update `docs/API.md` (or equivalent) if new endpoints are exposed downstream
- Run the project's lint command (`make check`, `golangci-lint run ./...`, etc.) to verify

## Checklist

- [ ] Preflight: `internal/adapters/clients/httpx/` confirmed present
- [ ] Domain interface defined in `internal/domain/<pkg>/`, no external deps
- [ ] Adapter implements interface (compile-time check: `var _ Interface = (*Impl)(nil)`)
- [ ] Uses `httpx.Client` (gets retry + circuit breaker automatically)
- [ ] `Available()` returns `false` when credentials empty
- [ ] Rate limiting added if the API has limits
- [ ] Tests use `httptest.NewServer`
- [ ] Environment variable added to config + `.env.example`
- [ ] Wired in `cmd/<app>/init.go` or equivalent
- [ ] `CLAUDE.md` updated

## Reference

`references/example-client.md` — full annotated walkthrough of `client.go`, `types.go`, and `client_test.go`. Read this before writing the adapter; it has the imports, error wrapping conventions, and test patterns to copy.

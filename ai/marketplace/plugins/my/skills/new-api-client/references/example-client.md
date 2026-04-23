# Example API Client — Annotated Walkthrough

This is a minimal but complete example of an external API client following the project's hexagonal architecture pattern. Use it as a reference when implementing a new integration with the `my:new-api-client` skill.

## Directory layout

```
internal/adapters/clients/acme/
├── client.go       # Client struct, constructor, interface methods
├── types.go        # API-specific request/response shapes
└── client_test.go  # Tests using httptest.NewServer
```

## client.go

```go
package acme

import (
    "context"
    "encoding/json"
    "fmt"
    "net/url"
    "time"

    // Replace <module> with the value from go.mod (e.g. github.com/you/project)
    "<module>/internal/adapters/clients/httpx"
    "<module>/internal/domain/observability"
    "<module>/internal/domain/widgets" // the domain package this adapter implements
)

// compile-time interface check — fails loudly if Client drifts from the interface
var _ widgets.Provider = (*Client)(nil)

const (
    baseURL        = "https://api.acme.example.com/v1"
    defaultTimeout = 15 * time.Second
)

type Client struct {
    httpClient *httpx.Client
    apiKey     string
    logger     observability.Logger
}

type Option func(*Client)

func WithLogger(logger observability.Logger) Option {
    return func(c *Client) { c.logger = logger }
}

// NewClient builds an Acme API client. Pass an empty apiKey to get a no-op
// client that reports Available() == false.
func NewClient(apiKey string, opts ...Option) *Client {
    cfg := httpx.DefaultConfig("Acme")
    cfg.DefaultTimeout = defaultTimeout
    c := &Client{
        apiKey:     apiKey,
        httpClient: httpx.NewClient(cfg),
    }
    for _, opt := range opts {
        opt(c)
    }
    return c
}

func (c *Client) Available() bool { return c.apiKey != "" }
func (c *Client) Name() string    { return "acme" }

// GetWidget fetches a single widget by ID from the Acme API.
func (c *Client) GetWidget(ctx context.Context, id string) (*widgets.Widget, error) {
    headers := map[string]string{
        "Authorization": "Bearer " + c.apiKey,
        "Accept":        "application/json",
    }

    endpoint := baseURL + "/widgets/" + url.PathEscape(id)
    resp, err := c.httpClient.Get(ctx, endpoint, headers, defaultTimeout)
    if err != nil {
        return nil, fmt.Errorf("acme get widget %s: %w", id, err)
    }

    var raw apiWidget
    if err := json.Unmarshal(resp.Body, &raw); err != nil {
        return nil, fmt.Errorf("acme parse widget response: %w", err)
    }

    return toWidget(raw), nil
}
```

## types.go

```go
package acme

import "<module>/internal/domain/widgets"

// apiWidget mirrors the Acme API's JSON shape. Keep it separate from the
// domain type so API schema changes don't bleed into the domain layer.
type apiWidget struct {
    ID    string `json:"id"`
    Name  string `json:"name"`
    Color string `json:"color"`
}

func toWidget(raw apiWidget) *widgets.Widget {
    return &widgets.Widget{
        ID:    raw.ID,
        Name:  raw.Name,
        Color: raw.Color,
    }
}
```

## client_test.go

```go
package acme_test

import (
    "context"
    "encoding/json"
    "net/http"
    "net/http/httptest"
    "testing"

    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/require"

    "<module>/internal/adapters/clients/acme"
)

func TestClient_GetWidget(t *testing.T) {
    srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        assert.Equal(t, "/v1/widgets/abc-123", r.URL.Path)
        assert.Equal(t, "Bearer test-key", r.Header.Get("Authorization"))
        json.NewEncoder(w).Encode(map[string]string{
            "id":    "abc-123",
            "name":  "Sprocket",
            "color": "blue",
        })
    }))
    defer srv.Close()

    // Point the client at the test server by swapping the base URL via an
    // unexported option — or by making baseURL a field configurable via an
    // option (preferred for testability).
    c := acme.NewClientWithBase(srv.URL+"/v1", "test-key")

    widget, err := c.GetWidget(context.Background(), "abc-123")
    require.NoError(t, err)
    assert.Equal(t, "abc-123", widget.ID)
    assert.Equal(t, "Sprocket", widget.Name)
}

func TestClient_Available(t *testing.T) {
    assert.True(t, acme.NewClient("some-key").Available())
    assert.False(t, acme.NewClient("").Available())
}
```

## Key patterns to copy

| Pattern | Why |
|---------|-----|
| `var _ Domain = (*Client)(nil)` | Compile-time interface check; catches drift immediately |
| `Available() bool` based on empty API key | Lets callers degrade gracefully when the integration isn't configured |
| Separate `apiWidget` / `toWidget()` | Decouples API schema from domain model |
| `fmt.Errorf("acme ...: %w", err)` | Preserves error chain with context about which client and operation failed |
| `httptest.NewServer` in tests | Real HTTP round-trip without hitting the actual API |
| `WithLogger` functional option | Keeps the constructor signature stable as cross-cutting concerns are added |

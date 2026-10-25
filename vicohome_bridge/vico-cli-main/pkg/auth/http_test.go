package auth

import (
	"io"
	"net/http"
	"strings"
	"testing"
)

type responseTransport struct {
	body   string
	status int
}

func (r responseTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	return &http.Response{StatusCode: r.status, Body: io.NopCloser(strings.NewReader(r.body)), Header: make(http.Header)}, nil
}
func TestExecuteRejectsAPIFailures(t *testing.T) {
	old := http.DefaultTransport
	defer func() { http.DefaultTransport = old }()
	for _, tt := range []responseTransport{{`{"result":99,"msg":"API failed"}`, 200}, {`{"code":99,"msg":"API failed"}`, 200}, {`{"code":0,"data":{"list":[]}}`, 500}, {`broken`, 200}} {
		http.DefaultTransport = tt
		req, _ := http.NewRequest("POST", "https://example.test", nil)
		if _, err := ExecuteWithRetry(req); err == nil {
			t.Errorf("accepted failure: %+v", tt)
		}
	}
}
func TestValidatePrettyJSON(t *testing.T) {
	if _, err := ValidateResponse([]byte("\n{\"code\":0}")); err != nil {
		t.Fatal(err)
	}
}

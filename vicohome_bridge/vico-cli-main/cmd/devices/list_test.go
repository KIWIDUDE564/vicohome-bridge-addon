package devices

import (
	"bytes"
	"errors"
	"testing"
)

func TestListJSONAndErrors(t *testing.T) {
	oldAuth, oldList := authenticate, fetchDeviceList
	defer func() { authenticate, fetchDeviceList = oldAuth, oldList }()
	authenticate = func() (string, error) { return "token", nil }
	fetchDeviceList = func(string) ([]Device, error) { return nil, nil }
	outputFormat = "json"
	var out bytes.Buffer
	listCmd.SetOut(&out)
	if err := listCmd.RunE(listCmd, nil); err != nil {
		t.Fatal(err)
	}
	if out.String() != "[]\n" {
		t.Fatal(out.String())
	}
	out.Reset()
	fetchDeviceList = func(string) ([]Device, error) { return nil, errors.New("API") }
	if err := listCmd.RunE(listCmd, nil); err == nil {
		t.Fatal("expected API error")
	}
	authenticate = func() (string, error) { return "", errors.New("auth") }
	if err := listCmd.RunE(listCmd, nil); err == nil {
		t.Fatal("expected auth error")
	}
	if out.Len() != 0 {
		t.Fatal("error on stdout")
	}
}

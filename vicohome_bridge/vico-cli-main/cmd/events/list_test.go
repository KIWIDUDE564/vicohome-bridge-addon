package events

import (
	"bytes"
	"encoding/json"
	"errors"
	"testing"
)

func TestEventClassification(t *testing.T) {
	for _, field := range []string{"eventType", "type", "event_type"} {
		e := transformRawEvent(map[string]interface{}{field: "person", "timestamp": float64(1700000000)})
		b, _ := json.Marshal(e)
		var out map[string]interface{}
		json.Unmarshal(b, &out)
		if out["eventType"] != "person" {
			t.Fatalf("lost %s: %s", field, b)
		}
		if e.Timestamp != "2023-11-14T22:13:20Z" {
			t.Fatal(e.Timestamp)
		}
	}
	b, _ := json.Marshal(transformRawEvent(map[string]interface{}{}))
	var out map[string]interface{}
	json.Unmarshal(b, &out)
	if out["eventType"] != "unknown" {
		t.Fatal(string(b))
	}
}
func TestListJSONAndErrors(t *testing.T) {
	oldAuth, oldFetch := authenticate, listEvents
	defer func() { authenticate, listEvents = oldAuth, oldFetch }()
	authenticate = func() (string, error) { return "token", nil }
	startTime, endTime = "2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z"
	outputFormat = "json"
	var out bytes.Buffer
	listCmd.SetOut(&out)
	listEvents = func(string, Request) ([]Event, error) { return nil, nil }
	if err := listCmd.RunE(listCmd, nil); err != nil {
		t.Fatal(err)
	}
	if out.String() != "[]\n" {
		t.Fatalf("empty output: %q", out.String())
	}
	for _, failAuth := range []bool{false, true} {
		out.Reset()
		if failAuth {
			authenticate = func() (string, error) { return "", errors.New("auth") }
		} else {
			listEvents = func(string, Request) ([]Event, error) { return nil, errors.New("API") }
		}
		if err := listCmd.RunE(listCmd, nil); err == nil {
			t.Fatal("expected error")
		}
		if out.Len() != 0 {
			t.Fatal("error polluted JSON stdout")
		}
	}
}

func TestTimestampVariantsAndBirdClassification(t *testing.T) {
	for _, stamp := range []interface{}{float64(1700000000000), "1700000000", "1700000000000", "2023-11-14 22:13:20", "2023-11-14T23:13:20+01:00"} {
		e := transformRawEvent(map[string]interface{}{"timestamp": stamp})
		if e.Timestamp != "2023-11-14T22:13:20Z" {
			t.Errorf("%v => %s", stamp, e.Timestamp)
		}
	}
	e := transformRawEvent(map[string]interface{}{"subcategoryInfoList": []interface{}{map[string]interface{}{"objectType": "bird", "objectName": "Robin"}}})
	b, _ := json.Marshal(e)
	var out map[string]interface{}
	json.Unmarshal(b, &out)
	if out["eventType"] != "bird" {
		t.Fatal(string(b))
	}
}

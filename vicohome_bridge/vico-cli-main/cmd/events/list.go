package events

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/dydx/vico-cli/pkg/auth"
	"github.com/spf13/cobra"
)

// Request represents the JSON request body sent to the Vicohome API
// when fetching events within a specific time range.
type Request struct {
	StartTimestamp string `json:"startTimestamp"` // Start time in Unix timestamp format
	EndTimestamp   string `json:"endTimestamp"`   // End time in Unix timestamp format
	Language       string `json:"language"`       // Language code (e.g., "en" for English)
	CountryNo      string `json:"countryNo"`      // Country code (e.g., "US" for United States)
}

// Event represents a Vicohome event with its properties as returned by the API.
// This structure contains information about bird sightings, including metadata
// about the device that captured the event, the bird identified, and media URLs.
type Event struct {
	EventType      string  `json:"eventType"`
	TraceID        string  `json:"traceId"`
	Timestamp      string  `json:"timestamp"`
	DeviceName     string  `json:"deviceName"`
	SerialNumber   string  `json:"serialNumber"`
	AdminName      string  `json:"adminName"`
	Period         string  `json:"period"`
	BirdName       string  `json:"birdName"`
	BirdLatin      string  `json:"birdLatin"`
	BirdConfidence float64 `json:"birdConfidence"`
	KeyShotURL     string  `json:"keyShotUrl"`
	ImageURL       string  `json:"imageUrl"`
	VideoURL       string  `json:"videoUrl"`

	// Internal field - not exported to JSON
	keyshots []map[string]interface{} `json:"-"`
}

var (
	startTime    string
	endTime      string
	outputFormat string
)

var authenticate = auth.Authenticate
var listEvents = fetchEvents

// listCmd represents the command to list events from the Vicohome API.
// It allows users to fetch events within a specified time range,
// and supports output in both table and JSON formats.
var listCmd = &cobra.Command{
	Use:   "list",
	Short: "List events within a specified time range",
	Long: `Fetch and display events from Vicohome API for the specified time period. 
Times should be in format: 2025-05-18 14:59:25`,
	RunE: func(cmd *cobra.Command, args []string) error {
		// Parse and validate time parameters
		start, end, err := parseTimeParameters(startTime, endTime)
		if err != nil {
			return fmt.Errorf("error parsing time parameters: %w", err)
		}

		token, err := authenticate()
		if err != nil {
			return fmt.Errorf("authentication failed: %w", err)
		}

		startTimestamp := fmt.Sprintf("%d", start.Unix())
		endTimestamp := fmt.Sprintf("%d", end.Unix())

		eventsReq := Request{
			StartTimestamp: startTimestamp,
			EndTimestamp:   endTimestamp,
			Language:       "en",
			CountryNo:      auth.GetCountryCode(),
		}

		events, err := listEvents(token, eventsReq)
		if err != nil {
			return fmt.Errorf("error fetching events: %w", err)
		}

		// Display events
		if len(events) == 0 && outputFormat != "json" {
			fmt.Fprintln(cmd.OutOrStdout(), "No events found in the specified time period.")
			return nil
		}

		// Write to stdout
		if outputFormat == "json" {
			if events == nil {
				events = []Event{}
			}
			return json.NewEncoder(cmd.OutOrStdout()).Encode(events)
		} else {
			// Output table format
			fmt.Printf("%-36s %-20s %-25s %-25s %-25s\n",
				"Trace ID", "Timestamp", "Device Name", "Bird Name", "Bird Latin")
			fmt.Println("--------------------------------------------------------------------------------------------------")
			for _, event := range events {
				fmt.Printf("%-36s %-20s %-25s %-25s %-25s\n",
					event.TraceID,
					event.Timestamp,
					event.DeviceName,
					event.BirdName,
					event.BirdLatin)
			}
		}
		return nil
	},
}

// supportedTimeFormats contains the timestamp formats that the handler can parse
var supportedTimeFormats = []string{
	"2006-01-02 15:04:05", // Standard format
	time.RFC3339,          // ISO 8601 format
}

// parseTimestamp attempts to parse a timestamp string using supported formats
func parseTimestamp(timestamp string) (time.Time, error) {
	var lastErr error

	// Try each supported format
	for _, format := range supportedTimeFormats {
		t, err := time.Parse(format, timestamp)
		if err == nil {
			return t, nil
		}
		lastErr = err
	}

	// If we get here, none of the formats worked
	return time.Time{}, lastErr
}

func init() {
	// Use UTC when generating the default window so the parsed timestamps
	// match the actual current time regardless of the host's timezone. When we
	// previously formatted the defaults in the local timezone (e.g. America/Los_Angeles)
	// but parsed them as UTC, the effective window ended several hours in the past,
	// preventing the bridge from ever seeing the most recent events.
	currentTime := time.Now().UTC()
	defaultStart := currentTime.Add(-24 * time.Hour).Format("2006-01-02 15:04:05")
	defaultEnd := currentTime.Format("2006-01-02 15:04:05")

	listCmd.Flags().StringVar(&startTime, "startTime", defaultStart, "Start time (format: 2006-01-02 15:04:05)")
	listCmd.Flags().StringVar(&endTime, "endTime", defaultEnd, "End time (format: 2006-01-02 15:04:05)")
	listCmd.Flags().StringVar(&outputFormat, "format", "table", "Output format (table or json)")
}

// fetchEvents retrieves events from the Vicohome API within the specified time range.
// It takes an authentication token and a Request object containing the time range
// parameters, and returns a slice of Event objects and any error encountered.
// This function handles the API request, response parsing, and error handling.
func fetchEvents(token string, request Request) ([]Event, error) {
	reqBody, err := json.Marshal(request)
	if err != nil {
		return nil, fmt.Errorf("error marshaling request: %w", err)
	}

	apiURL := auth.BuildAPIURL("/library/newselectlibrary")
	req, err := http.NewRequest("POST", apiURL, bytes.NewBuffer(reqBody))
	if err != nil {
		return nil, fmt.Errorf("error creating request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Authorization", token)

	// Use ExecuteWithRetry for automatic token refresh
	respBody, err := auth.ExecuteWithRetry(req)
	if err != nil {
		return nil, fmt.Errorf("error making request: %w", err)
	}

	// Parse response
	var responseMap map[string]interface{}
	if err := json.Unmarshal(respBody, &responseMap); err != nil {
		return nil, fmt.Errorf("error unmarshaling response: %w\nResponse: %s", err, string(respBody))
	}

	// Check for API errors
	if code, ok := responseMap["code"].(float64); ok && code != 0 {
		msg, _ := responseMap["msg"].(string)
		return nil, fmt.Errorf("API returned error: %s (code: %.0f)", msg, code)
	}

	// Extract the event list
	data, ok := responseMap["data"].(map[string]interface{})
	if !ok {
		return []Event{}, nil
	}

	eventList, ok := data["list"].([]interface{})
	if !ok {
		return []Event{}, nil
	}

	// Transform events to our simpler format
	events := make([]Event, 0, len(eventList))
	for _, item := range eventList {
		if eventMap, ok := item.(map[string]interface{}); ok {
			// Transform the event to our format
			transformedEvent := transformRawEvent(eventMap)
			events = append(events, transformedEvent)
		}
	}

	return events, nil
}

// transformRawEvent converts a map of event data from the API response into an Event struct.
// It safely extracts and type-converts the various event properties from the dynamic map
// into the strongly-typed Event structure. It handles special processing for bird information,
// timestamps, and keyshots. Default values are provided for missing or unidentified fields.
func transformRawEvent(eventMap map[string]interface{}) Event {
	event := Event{EventType: "unknown"}
	for _, key := range []string{"eventType", "type", "event_type"} {
		if value, ok := eventMap[key].(string); ok && value != "" {
			event.EventType = value
			break
		}
	}

	// Extract string fields
	if val, ok := eventMap["traceId"].(string); ok {
		event.TraceID = val
	}

	// Normalize all supported timestamps to UTC so ordering never depends on host timezone.
	switch value := eventMap["timestamp"].(type) {
	case float64:
		event.Timestamp = unixEventTime(value)
	case string:
		if number, err := strconv.ParseFloat(value, 64); err == nil {
			event.Timestamp = unixEventTime(number)
		} else if stamp, err := parseTimestamp(value); err == nil {
			event.Timestamp = stamp.UTC().Format(time.RFC3339)
		} else {
			event.Timestamp = value
		}
	}

	if val, ok := eventMap["deviceName"].(string); ok {
		event.DeviceName = val
	}
	if val, ok := eventMap["serialNumber"].(string); ok {
		event.SerialNumber = val
	}
	if val, ok := eventMap["adminName"].(string); ok {
		event.AdminName = val
	}

	// Fix: Handle period as a number
	if val, ok := eventMap["period"].(float64); ok {
		event.Period = fmt.Sprintf("%.2fs", val)
	} else if val, ok := eventMap["period"].(string); ok {
		event.Period = val
	}

	if val, ok := eventMap["imageUrl"].(string); ok {
		event.ImageURL = val
	}
	if val, ok := eventMap["videoUrl"].(string); ok {
		event.VideoURL = val
	}

	// Set default bird name
	event.BirdName = "Unidentified"

	// Process subcategoryInfoList for bird data
	if subcategoryInfoList, ok := eventMap["subcategoryInfoList"].([]interface{}); ok && len(subcategoryInfoList) > 0 {
		for _, info := range subcategoryInfoList {
			if infoMap, ok := info.(map[string]interface{}); ok {
				// Check if this is a bird entry
				if objectType, ok := infoMap["objectType"].(string); ok && objectType == "bird" {
					// Preserve the explicit API classification when no event type was supplied.
					if event.EventType == "unknown" {
						event.EventType = "bird"
					}
					// Extract bird name
					if birdName, ok := infoMap["objectName"].(string); ok {
						event.BirdName = birdName
					}
					// Extract Latin name
					if birdLatin, ok := infoMap["birdStdName"].(string); ok {
						event.BirdLatin = birdLatin
					}
					// Extract confidence
					if confidence, ok := infoMap["confidence"].(float64); ok {
						event.BirdConfidence = confidence
					}
					break
				}
			}
		}
	}

	// Handle the keyshots field separately
	if keyshots, ok := eventMap["keyshots"].([]interface{}); ok {
		transformedKeyshots := make([]map[string]interface{}, 0, len(keyshots))
		for _, ks := range keyshots {
			if ksMap, ok := ks.(map[string]interface{}); ok {
				// Create new keyshot with just the desired fields
				newKeyshot := make(map[string]interface{})
				// Copy needed fields
				if url, ok := ksMap["imageUrl"].(string); ok {
					newKeyshot["imageUrl"] = url
					// Extract the first keyshot URL for the flat structure
					if event.KeyShotURL == "" {
						event.KeyShotURL = url
					}
				}
				if msg, ok := ksMap["message"].(string); ok {
					newKeyshot["message"] = msg
				}
				if cat, ok := ksMap["objectCategory"].(string); ok {
					newKeyshot["objectCategory"] = cat
				}
				if sub, ok := ksMap["subCategoryName"].(string); ok {
					newKeyshot["subCategoryName"] = sub
				}
				transformedKeyshots = append(transformedKeyshots, newKeyshot)
			}
		}
		event.keyshots = transformedKeyshots
	} else {
		event.keyshots = []map[string]interface{}{}
	}

	return event
}

// unixEventTime accepts API timestamps in seconds or milliseconds.
func unixEventTime(value float64) string {
	if value > 100000000000 {
		value /= 1000
	}
	return time.Unix(int64(value), 0).UTC().Format(time.RFC3339)
}

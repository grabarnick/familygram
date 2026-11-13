package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// SMSSender delivers a login code to a phone number (E.164).
type SMSSender interface {
	Send(ctx context.Context, phone, text string) error
}

func newSMSSender(provider string) (SMSSender, error) {
	client := &http.Client{Timeout: 15 * time.Second}
	need := func(keys ...string) error {
		for _, k := range keys {
			if os.Getenv(k) == "" {
				return fmt.Errorf("FG_SMS_PROVIDER=%s requires %s", provider, k)
			}
		}
		return nil
	}
	switch provider {
	case "", "log":
		return logSender{}, nil
	case "smsru":
		if err := need("FG_SMSRU_API_ID"); err != nil {
			return nil, err
		}
		return &smsruSender{apiID: os.Getenv("FG_SMSRU_API_ID"), client: client}, nil
	case "smsc":
		if err := need("FG_SMSC_LOGIN", "FG_SMSC_PASSWORD"); err != nil {
			return nil, err
		}
		return &smscSender{login: os.Getenv("FG_SMSC_LOGIN"), password: os.Getenv("FG_SMSC_PASSWORD"), client: client}, nil
	case "twilio":
		if err := need("FG_TWILIO_SID", "FG_TWILIO_TOKEN", "FG_TWILIO_FROM"); err != nil {
			return nil, err
		}
		return &twilioSender{sid: os.Getenv("FG_TWILIO_SID"), token: os.Getenv("FG_TWILIO_TOKEN"),
			from: os.Getenv("FG_TWILIO_FROM"), client: client}, nil
	}
	return nil, fmt.Errorf("unknown FG_SMS_PROVIDER %q (log, smsru, smsc, twilio)", provider)
}

// logSender writes the message to the server log (development / tiny installs).
type logSender struct{}

func (logSender) Send(_ context.Context, phone, text string) error {
	log.Printf("SMS to %s: %s", phone, text)
	return nil
}

func readBody(resp *http.Response) ([]byte, error) {
	defer resp.Body.Close()
	return io.ReadAll(io.LimitReader(resp.Body, 64<<10))
}

// sms.ru — https://sms.ru/api/send
type smsruSender struct {
	apiID  string
	client *http.Client
}

func (s *smsruSender) Send(ctx context.Context, phone, text string) error {
	q := url.Values{"api_id": {s.apiID}, "to": {strings.TrimPrefix(phone, "+")}, "msg": {text}, "json": {"1"}}
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, "https://sms.ru/sms/send?"+q.Encode(), nil)
	resp, err := s.client.Do(req)
	if err != nil {
		return err
	}
	body, err := readBody(resp)
	if err != nil {
		return err
	}
	var out struct {
		Status     string `json:"status"`
		StatusText string `json:"status_text"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return fmt.Errorf("sms.ru: bad response: %s", body)
	}
	if out.Status != "OK" {
		return fmt.Errorf("sms.ru: %s", out.StatusText)
	}
	return nil
}

// smsc.ru — https://smsc.ru/api/http/
type smscSender struct {
	login, password string
	client          *http.Client
}

func (s *smscSender) Send(ctx context.Context, phone, text string) error {
	q := url.Values{"login": {s.login}, "psw": {s.password}, "phones": {strings.TrimPrefix(phone, "+")},
		"mes": {text}, "fmt": {"3"}, "charset": {"utf-8"}}
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, "https://smsc.ru/sys/send.php?"+q.Encode(), nil)
	resp, err := s.client.Do(req)
	if err != nil {
		return err
	}
	body, err := readBody(resp)
	if err != nil {
		return err
	}
	var out struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return fmt.Errorf("smsc.ru: bad response: %s", body)
	}
	if out.Error != "" {
		return fmt.Errorf("smsc.ru: %s", out.Error)
	}
	return nil
}

// Twilio — https://www.twilio.com/docs/sms/api/message-resource
type twilioSender struct {
	sid, token, from string
	client           *http.Client
}

func (s *twilioSender) Send(ctx context.Context, phone, text string) error {
	form := url.Values{"To": {phone}, "From": {s.from}, "Body": {text}}
	u := "https://api.twilio.com/2010-04-01/Accounts/" + url.PathEscape(s.sid) + "/Messages.json"
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, u, strings.NewReader(form.Encode()))
	req.SetBasicAuth(s.sid, s.token)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := s.client.Do(req)
	if err != nil {
		return err
	}
	body, err := readBody(resp)
	if err != nil {
		return err
	}
	if resp.StatusCode >= 300 {
		return fmt.Errorf("twilio: %d %s", resp.StatusCode, body)
	}
	return nil
}

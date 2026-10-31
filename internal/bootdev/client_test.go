package bootdev

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync"
	"testing"
	"time"
)

// server answers each request with the next of codes (200 once they run out) and records the
// requests it saw.
type server struct {
	mu       sync.Mutex
	codes    []int
	headers  map[string]string // added to error answers
	seen     []*http.Request
	times    []time.Time
	slowness time.Duration
}

func (s *server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	s.seen = append(s.seen, r)
	s.times = append(s.times, time.Now())
	code := http.StatusOK
	if len(s.codes) > 0 {
		code, s.codes = s.codes[0], s.codes[1:]
	}
	slow := s.slowness
	s.mu.Unlock()
	if slow > 0 {
		select {
		case <-time.After(slow):
		case <-r.Context().Done():
			return
		}
	}
	if code != http.StatusOK {
		for k, v := range s.headers {
			w.Header().Set(k, v)
		}
		w.WriteHeader(code)
		return
	}
	w.Write([]byte("page " + r.URL.Path))
}

func newTest(t *testing.T, s *server, opts ...Option) *Client {
	t.Helper()
	ts := httptest.NewServer(s)
	t.Cleanup(ts.Close)
	c, err := New(append([]Option{WithBaseURL(ts.URL), WithDelay(0), WithRetries(3, time.Millisecond)}, opts...)...)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func TestGetRetries(t *testing.T) {
	for _, tc := range []struct {
		name     string
		codes    []int
		retries  int
		wantCode int // 0: success
		tries    int
	}{
		{name: "ok at once", tries: 1},
		{name: "busy, then ok", codes: []int{503, 502}, retries: 3, tries: 3},
		{name: "too many requests, then ok", codes: []int{429}, retries: 3, tries: 2},
		{name: "busy until it gives up", codes: []int{500, 500, 500, 500, 500}, retries: 3, wantCode: 500, tries: 4},
		{name: "not found is not retried", codes: []int{404}, retries: 3, wantCode: 404, tries: 1},
		{name: "forbidden is not retried", codes: []int{403}, retries: 3, wantCode: 403, tries: 1},
		{name: "no retries asked for", codes: []int{503}, retries: 0, wantCode: 503, tries: 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := &server{codes: tc.codes}
			c := newTest(t, s, WithRetries(tc.retries, time.Millisecond))
			body, err := c.Get(context.Background(), "/courses")
			var se *StatusError
			switch {
			case tc.wantCode == 0 && err != nil:
				t.Fatalf("Get: %v", err)
			case tc.wantCode == 0 && string(body) != "page /courses":
				t.Errorf("body = %q", body)
			case tc.wantCode != 0 && (!errors.As(err, &se) || se.Code != tc.wantCode):
				t.Errorf("Get: err = %v, want status %d", err, tc.wantCode)
			}
			if len(s.seen) != tc.tries || c.Loads() != tc.tries {
				t.Errorf("tries = %d (Loads %d), want %d", len(s.seen), c.Loads(), tc.tries)
			}
		})
	}
}

func TestGetHonorsRetryAfter(t *testing.T) {
	s := &server{codes: []int{429}, headers: map[string]string{"Retry-After": "1"}}
	c := newTest(t, s, WithRetries(1, time.Hour)) // the backoff alone would wait an hour
	start := time.Now()
	if _, err := c.Get(context.Background(), "/x"); err != nil {
		t.Fatal(err)
	}
	if took := time.Since(start); took < time.Second || took > 10*time.Second {
		t.Errorf("waited %s, want the 1 s Retry-After asked for", took)
	}
}

func TestGetSendsItsUserAgent(t *testing.T) {
	s := &server{}
	c := newTest(t, s)
	if _, err := c.Get(context.Background(), "/lessons/x"); err != nil {
		t.Fatal(err)
	}
	r := s.seen[0]
	if got := r.Header.Get("User-Agent"); got != UserAgent {
		t.Errorf("User-Agent = %q", got)
	}
	if r.Method != http.MethodGet || r.URL.Path != "/lessons/x" {
		t.Errorf("request = %s %s", r.Method, r.URL.Path)
	}
}

func TestGetPausesBetweenRequests(t *testing.T) {
	s := &server{}
	const delay = 60 * time.Millisecond
	c := newTest(t, s, WithDelay(delay))
	for i := range 4 {
		if _, err := c.Get(context.Background(), "/p"+strconv.Itoa(i)); err != nil {
			t.Fatal(err)
		}
	}
	for i := 1; i < len(s.times); i++ {
		if gap := s.times[i].Sub(s.times[i-1]); gap < delay || gap > 2*delay+200*time.Millisecond {
			t.Errorf("gap %d = %s, want between %s and %s", i, gap, delay, 2*delay)
		}
	}
}

func TestBootDevIsAlwaysAskedPolitely(t *testing.T) {
	c, err := New(WithDelay(0))
	if err != nil {
		t.Fatal(err)
	}
	if c.delay != MinDelay {
		t.Errorf("delay = %s for boot.dev, want %s", c.delay, MinDelay)
	}
}

func TestGetTimesOut(t *testing.T) {
	s := &server{slowness: time.Second}
	c := newTest(t, s, WithTimeout(50*time.Millisecond), WithRetries(0, 0))
	_, err := c.Get(context.Background(), "/slow")
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("Get of a slow page: err = %v, want a deadline error", err)
	}
}

func TestGetStopsWhenCancelled(t *testing.T) {
	s := &server{codes: []int{503, 503, 503}}
	c := newTest(t, s, WithRetries(3, time.Hour))
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := c.Get(ctx, "/busy")
	if !errors.Is(err, context.DeadlineExceeded) || time.Since(start) > 5*time.Second {
		t.Errorf("Get: err = %v after %s, want it to stop with the context", err, time.Since(start))
	}
}

func TestGetStaysOnItsSite(t *testing.T) {
	elsewhere := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("elsewhere")) }))
	defer elsewhere.Close()
	mux := http.NewServeMux()
	mux.HandleFunc("/away", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, elsewhere.URL+"/x", http.StatusFound)
	})
	mux.HandleFunc("/home", func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, "/courses", http.StatusFound) })
	mux.HandleFunc("/courses", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("catalog")) })
	ts := httptest.NewServer(mux)
	defer ts.Close()
	c, err := New(WithBaseURL(ts.URL), WithDelay(0), WithRetries(3, time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.Get(context.Background(), "/away"); !errors.Is(err, ErrOffSite) {
		t.Errorf("redirect to another site: err = %v, want ErrOffSite", err)
	}
	if body, err := c.Get(context.Background(), "/home"); err != nil || string(body) != "catalog" {
		t.Errorf("redirect on the site: %q, %v", body, err)
	}
	for _, p := range []string{"https://example.com/x", "//example.com/x", "lessons/x", ""} {
		if _, err := c.Get(context.Background(), p); err == nil {
			t.Errorf("Get(%q) should be refused", p)
		}
	}
	if _, err := c.LessonPage(context.Background(), "../courses"); err == nil {
		t.Error("LessonPage with a path for a uuid should be refused")
	}
}

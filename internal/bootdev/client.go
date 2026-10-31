// Package bootdev reads boot.dev's public pages: the course catalog, and lesson pages, which
// hold a lesson and the outline of its course in the data Nuxt renders them from.
//
// The client is polite: one request at a time, a pause of 2 to 4 seconds between them, a
// User-Agent that says what it is, and backoff when the site is busy. It only ever asks its
// own site for pages, never for images or videos.
package bootdev

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math/rand/v2"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"sync"
	"time"
)

const (
	// BaseURL is boot.dev's site.
	BaseURL = "https://www.boot.dev"
	// UserAgent says who is asking, and why.
	UserAgent = "gopherwood-sync/1.0 (personal offline study copy of boot.dev's Go courses; one page at a time, 2-4 s apart)"
	// MinDelay is the shortest pause between two requests to boot.dev; up to as much again is
	// added at random.
	MinDelay = 2 * time.Second

	maxBody = 16 << 20
)

// Client loads pages of one site, one at a time.
type Client struct {
	base    *url.URL
	http    *http.Client
	delay   time.Duration // shortest pause between requests
	timeout time.Duration // for one request
	retries int           // after the first try
	backoff time.Duration // the first wait before a retry; it doubles each time
	logf    func(format string, args ...any)

	mu    sync.Mutex // one request at a time
	last  time.Time
	loads int
}

// Option configures a Client.
type Option func(*Client)

// WithBaseURL points the client at another site, such as a test server. boot.dev is always
// asked at its polite pace, whatever WithDelay says.
func WithBaseURL(u string) Option { return func(c *Client) { c.base, _ = url.Parse(u) } }

// WithDelay sets the shortest pause between requests.
func WithDelay(d time.Duration) Option { return func(c *Client) { c.delay = d } }

// WithTimeout sets how long one request may take.
func WithTimeout(d time.Duration) Option { return func(c *Client) { c.timeout = d } }

// WithRetries sets how many times a request is tried again on 429, 5xx or a network error,
// and the first wait before trying again.
func WithRetries(n int, backoff time.Duration) Option {
	return func(c *Client) { c.retries, c.backoff = n, backoff }
}

// WithLogger reports retries.
func WithLogger(logf func(format string, args ...any)) Option {
	return func(c *Client) { c.logf = logf }
}

// New returns a client for boot.dev, or the site WithBaseURL names.
func New(opts ...Option) (*Client, error) {
	c := &Client{delay: MinDelay, timeout: 30 * time.Second, retries: 3, backoff: 10 * time.Second, logf: func(string, ...any) {}}
	c.base, _ = url.Parse(BaseURL)
	for _, o := range opts {
		o(c)
	}
	if c.base == nil || c.base.Host == "" || (c.base.Scheme != "https" && c.base.Scheme != "http") {
		return nil, errors.New("bootdev: a base URL needs a scheme and a host")
	}
	if c.base.Host == "www.boot.dev" {
		c.delay = max(c.delay, MinDelay)
	}
	c.http = &http.Client{CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if req.URL.Host != c.base.Host || req.URL.Scheme != c.base.Scheme {
			return fmt.Errorf("%w: %s", ErrOffSite, req.URL)
		}
		if len(via) >= 5 {
			return fmt.Errorf("%w: more than 5 redirects", ErrOffSite)
		}
		return nil
	}}
	return c, nil
}

// ErrOffSite is a redirect the client refused to follow: to another site, or one too many.
var ErrOffSite = errors.New("refusing the redirect")

// Loads counts the requests made so far, retries included.
func (c *Client) Loads() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.loads
}

// StatusError is a response other than 200 OK.
type StatusError struct {
	URL    string
	Code   int
	Status string
}

func (e *StatusError) Error() string { return e.URL + ": " + e.Status }

// retryable marks an error worth trying again after a pause.
type retryable struct {
	err   error
	after time.Duration // what Retry-After asked for, if anything
}

func (r *retryable) Error() string { return r.err.Error() }
func (r *retryable) Unwrap() error { return r.err }

// Get loads the page at path, such as "/courses", from the client's site.
func (c *Client) Get(ctx context.Context, path string) ([]byte, error) {
	ref, err := url.Parse(path)
	if err != nil || ref.IsAbs() || ref.Host != "" || len(path) == 0 || path[0] != '/' {
		return nil, fmt.Errorf("bootdev: %q is not a path on %s", path, c.base.Host)
	}
	u := c.base.ResolveReference(ref)

	c.mu.Lock()
	defer c.mu.Unlock()
	for attempt := 0; ; attempt++ {
		if !c.last.IsZero() && c.delay > 0 {
			if err := sleep(ctx, time.Until(c.last.Add(c.delay+rand.N(c.delay)))); err != nil {
				return nil, err
			}
		}
		body, err := c.once(ctx, u)
		if err == nil {
			return body, nil
		}
		var r *retryable
		if !errors.As(err, &r) {
			return nil, err
		}
		if attempt >= c.retries || ctx.Err() != nil {
			return nil, r.err
		}
		wait := c.backoff << attempt
		if r.after > 0 {
			wait = r.after
		}
		c.logf("%v; trying again in %s", r.err, wait)
		if err := sleep(ctx, wait); err != nil {
			return nil, err
		}
	}
}

func (c *Client) once(ctx context.Context, u *url.URL) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", UserAgent)
	req.Header.Set("Accept", "text/html")
	req.Header.Set("Accept-Language", "en")
	c.loads++
	defer func() { c.last = time.Now() }() // the next pause counts from the end of this load
	resp, err := c.http.Do(req)
	if err != nil {
		if errors.Is(err, ErrOffSite) {
			return nil, err
		}
		return nil, &retryable{err: fmt.Errorf("loading %s: %w", u, err)}
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxBody+1))
	switch {
	case err != nil:
		return nil, &retryable{err: fmt.Errorf("reading %s: %w", u, err)}
	case len(body) > maxBody:
		return nil, fmt.Errorf("%s: larger than %d MB", u, maxBody>>20)
	case resp.StatusCode == http.StatusOK:
		return body, nil
	}
	serr := &StatusError{URL: u.String(), Code: resp.StatusCode, Status: resp.Status}
	if resp.StatusCode == http.StatusTooManyRequests || resp.StatusCode >= 500 {
		return nil, &retryable{err: serr, after: retryAfter(resp.Header.Get("Retry-After"))}
	}
	return nil, serr
}

// retryAfter reads a Retry-After header: seconds, or an HTTP date.
func retryAfter(v string) time.Duration {
	if v == "" {
		return 0
	}
	if s, err := strconv.Atoi(v); err == nil && s > 0 {
		return time.Duration(s) * time.Second
	}
	if t, err := http.ParseTime(v); err == nil {
		return max(time.Until(t), 0)
	}
	return 0
}

func sleep(ctx context.Context, d time.Duration) error {
	if d <= 0 {
		return ctx.Err()
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// Page loads a page and decodes the data Nuxt rendered it from.
func (c *Client) Page(ctx context.Context, path string) (map[string]any, error) {
	body, err := c.Get(ctx, path)
	if err != nil {
		return nil, err
	}
	root, err := PageData(body)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return root, nil
}

// Catalog loads the course catalog.
func (c *Client) Catalog(ctx context.Context) ([]Course, error) {
	root, err := c.Page(ctx, "/courses")
	if err != nil {
		return nil, err
	}
	return ParseCatalog(root)
}

var reUUID = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// LessonPage loads the page of one lesson.
func (c *Client) LessonPage(ctx context.Context, uuid string) (map[string]any, error) {
	if !reUUID.MatchString(uuid) {
		return nil, fmt.Errorf("bootdev: %q is not a lesson uuid", uuid)
	}
	return c.Page(ctx, "/lessons/"+uuid)
}

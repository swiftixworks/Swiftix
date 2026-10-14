package http

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"sync"
	"time"
)

// TimeoutHandler returns a handler that runs h with dt to answer: h's
// response is kept and sent when h returns in time, and otherwise the
// client gets "503 Service Unavailable" with msg as the body (a short HTML
// page when msg is empty), and h's writes from then on fail with
// ErrHandlerTimeout. The context of h's request is done at dt.
func TimeoutHandler(h Handler, dt time.Duration, msg string) Handler {
	return &timeoutHandler{
		handler: h,
		body:    msg,
		dt:      dt,
	}
}

// ErrHandlerTimeout is what a handler that TimeoutHandler gave up on gets
// from Write.
var ErrHandlerTimeout = errors.New("http: Handler timeout")

type timeoutHandler struct {
	handler Handler
	body    string
	dt      time.Duration
}

func (h *timeoutHandler) errorBody() string {
	if h.body != "" {
		return h.body
	}
	return "<html><head><title>Timeout</title></head><body><h1>Timeout</h1></body></html>"
}

func (h *timeoutHandler) ServeHTTP(w ResponseWriter, r *Request) {
	ctx, cancelCtx := context.WithTimeout(r.Context(), h.dt)
	defer cancelCtx()
	r = r.WithContext(ctx)
	done := make(chan struct{})
	tw := &timeoutWriter{
		w:   w,
		h:   Header{},
		req: r,
	}
	panicChan := make(chan any, 1)
	go func() {
		defer func() {
			if p := recover(); p != nil {
				panicChan <- p
			}
		}()
		h.handler.ServeHTTP(tw, r)
		close(done)
	}()
	select {
	case p := <-panicChan:
		panic(p)
	case <-done:
		tw.mu.Lock()
		defer tw.mu.Unlock()
		dst := w.Header()
		for k, vv := range tw.h {
			dst[k] = vv
		}
		if !tw.wroteHeader {
			tw.code = StatusOK
		}
		w.WriteHeader(tw.code)
		w.Write(tw.wbuf)
	case <-ctx.Done():
		tw.mu.Lock()
		defer tw.mu.Unlock()
		switch err := ctx.Err(); err {
		case context.DeadlineExceeded:
			w.WriteHeader(StatusServiceUnavailable)
			io.WriteString(w, h.errorBody())
			tw.err = ErrHandlerTimeout
		default:
			w.WriteHeader(StatusServiceUnavailable)
			tw.err = err
		}
	}
}

// A timeoutWriter keeps what the handler of a TimeoutHandler writes until
// it is known to be in time.
type timeoutWriter struct {
	w    ResponseWriter
	h    Header
	wbuf []byte
	req  *Request

	mu          sync.Mutex
	err         error
	wroteHeader bool
	code        int
}

func (tw *timeoutWriter) Header() Header { return tw.h }

func (tw *timeoutWriter) Write(p []byte) (int, error) {
	tw.mu.Lock()
	defer tw.mu.Unlock()
	if tw.err != nil {
		return 0, tw.err
	}
	if !tw.wroteHeader {
		tw.writeHeaderLocked(StatusOK)
	}
	tw.wbuf = append(tw.wbuf, p...)
	return len(p), nil
}

func (tw *timeoutWriter) writeHeaderLocked(code int) {
	if code < 100 || code > 999 {
		panic(fmt.Sprintf("invalid WriteHeader code %v", code))
	}
	switch {
	case tw.err != nil:
		return
	case tw.wroteHeader:
		log.Printf("http: superfluous response.WriteHeader call")
	default:
		tw.wroteHeader = true
		tw.code = code
	}
}

func (tw *timeoutWriter) WriteHeader(code int) {
	tw.mu.Lock()
	defer tw.mu.Unlock()
	tw.writeHeaderLocked(code)
}

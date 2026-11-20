// hop is one service in the benchmark chain. It answers GET / and, when
// NEXT is set, calls the next service first and fails with 502 if that call fails.
package main

import (
	"context"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	next := os.Getenv("NEXT")
	name := os.Getenv("NAME")
	client := &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{
			MaxIdleConns:        1024,
			MaxIdleConnsPerHost: 1024,
			IdleConnTimeout:     90 * time.Second,
		},
	}

	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if next != "" {
			resp, err := client.Get(next)
			if err != nil {
				http.Error(w, name+": "+err.Error(), http.StatusBadGateway)
				return
			}
			io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
			if resp.StatusCode != http.StatusOK {
				http.Error(w, name+": upstream "+resp.Status, http.StatusBadGateway)
				return
			}
		}
		io.WriteString(w, name+" ok\n")
	})
	srv := &http.Server{Addr: ":8080"}
	go func() {
		log.Printf("%s listening on :8080, next=%q", name, next)
		if err := srv.ListenAndServe(); err != http.ErrServerClosed {
			log.Fatal(err)
		}
	}()

	// On SIGTERM keep serving while the endpoint is removed, then drain.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, os.Interrupt)
	<-stop
	time.Sleep(5 * time.Second)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	srv.Shutdown(ctx)
}

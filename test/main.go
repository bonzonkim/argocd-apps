package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
)

func LogginMiddleWare(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Printf("Requested URL: %s | Method: %s", r.URL, r.Method)
		next.ServeHTTP(w, r)
	})
}

func HelloHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)

	res := map[string]string{
		"msg": "hello world",
	}

	if err := json.NewEncoder(w).Encode(res); err != nil {
		log.Printf("Failed to encode response : %v", err)
	}
}

func AsdfHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)

	res := map[string]string{
		"msg": "ya-ho",
	}

	if err := json.NewEncoder(w).Encode(res); err != nil {
		log.Printf("Failed to encode response : %v", err)
	}
}

func main() {
	const port = ":8080"
	http.Handle("/hello", LogginMiddleWare(http.HandlerFunc(HelloHandler)))
	http.Handle("/asdf", LogginMiddleWare(http.HandlerFunc(AsdfHandler)))
	fmt.Printf("Server listening on port %v", port)

	if err := http.ListenAndServe(port, nil); err != nil {
		panic(err)
	}
}

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

type User struct {
	Name     string `json:"name,omitempty"`
	Password string `json:"password,omitempty"`
}

func UserHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowd", http.StatusMethodNotAllowed)
		return
	}

	var user User
	if err := json.NewDecoder(r.Body).Decode(&user); err != nil {
		http.Error(w, "Invalid JSON", http.StatusBadRequest)
		return
	}

	log.Printf("Received JSON: %+v", user)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"msg": fmt.Sprintf("Hello, %s", user.Name),
	})
}

func main() {
	const port = ":8080"
	http.Handle("/hello", LogginMiddleWare(http.HandlerFunc(HelloHandler)))
	http.Handle("/asdf", LogginMiddleWare(http.HandlerFunc(AsdfHandler)))
	http.Handle("/user", LogginMiddleWare(http.HandlerFunc(UserHandler)))
	fmt.Printf("Server listening on port %v", port)

	if err := http.ListenAndServe(port, nil); err != nil {
		panic(err)
	}
}

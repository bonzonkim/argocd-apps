package handler

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"

	"github.com/bonzonkim/ip.bumgu.com/api"
)

type response struct {
	Message string `json:"message"`
}

func HandlerMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Printf("Requested Path: %s || Requested Method: %s", r.URL.Path, r.Method)
		next.ServeHTTP(w, r)
	})
}
func IpHandler(w http.ResponseWriter, r *http.Request) {
	ip := api.GetIp(r)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)

	res := response{
		Message: fmt.Sprintf("Your IP %s", ip),
	}

	if err := json.NewEncoder(w).Encode(res); err != nil {
		log.Println("Failed to encode response")
	}
}

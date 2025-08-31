package main

import (
	"fmt"
	"net/http"

	"github.com/bonzonkim/ip.bumgu.com/handler"
)

func main() {
	http.Handle("/", handler.HandlerMiddleware(http.HandlerFunc(handler.IpHandler)))

	fmt.Println("Server running on port :8080")

	if err := http.ListenAndServe(":8080", nil); err != nil {
		fmt.Errorf("Failed to run server: %s", err)
	}
}

package api

import (
	"net/http"
	"strings"
)

func GetIp(r *http.Request) string {
	// proxy checking
	ip := r.Header.Get("X-Forwarded-For")

	if ip == "" {
		ip = r.RemoteAddr
	} else {
		// if there is more than 1 IP, returns the first IP
		ip = strings.Split(ip, ",")[0]
	}
	if strings.Contains(ip, ":") {
		ip, _, _ = strings.Cut(ip, ":")
	}
	return ip
}

package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHelloHandler(t *testing.T) {
	req := httptest.NewRequest("GET", "/hello", nil)
	rr := httptest.NewRecorder()

	handler := LogginMiddleWare(http.HandlerFunc(HelloHandler))
	handler.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("Expected status 200 OK, got %d", rr.Code)
	}
}

func TestAsdfHandler(t *testing.T) {
	req := httptest.NewRequest("GET", "/asdf", nil)
	rr := httptest.NewRecorder()

	handler := LogginMiddleWare(http.HandlerFunc(AsdfHandler))
	handler.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("Expected status 200 OK, got %d", rr.Code)
	}
}

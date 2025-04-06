package types

type User struct {
	Name     string `json:"name,omitempty"`
	Password string `json:"password,omitempty"`
}

type Item struct {
	Name    string `json:"name,omitempty"`
	Company string `json:"company,omitempty"`
}

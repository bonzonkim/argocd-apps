const http = require('http')
const port = 3000
const server = http.createServer((req, res) => {
  if (req.url === '/') {
    res.end("hello world")
  }
})


server.listen(port, () => {
  console.log(`server listening on port: ${port}`)
})

import { Hono } from 'hono'
import { prettyJSON } from 'hono/pretty-json'

const app = new Hono()

app.use(prettyJSON())
app.get('/', (c) => {
  return c.text('Hello Argo!')
})

app.get('/hello', (c) => {
  return c.json({message: "you've reached hidden endpoint!"})
})

export default app

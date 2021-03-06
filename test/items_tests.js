const chai = require('chai')
const expect = chai.expect
const chaiHttp = require('chai-http')
const bodyParser = require('body-parser')

chai.use(chaiHttp)
const express = require('express')
const memstore = require('../app/database/memstore')
const items = require('../app/routes/items')

function allowErrorResponse(allowedErrors, promise) {
  return promise.catch(err => {
    if (allowedErrors.includes(err.status)) {
      return err.response
    }
    throw err
  })
}

function applicationErrorHandler(err, req, res, next) {
  const status = err.errorCode || 500
  res.status(status).send(JSON.stringify(err.message))
}

describe('Items', () => {
  var store
  var app

  beforeEach(() => {
    store = memstore.create()
    app = express()
    collection = store.collection('TodoItem')
    app.use(bodyParser.json())
    app.use((req, res, next) => {
      req.user = { id: 'valid' }
      next()
    })
    app.use(items.createRouter(store))
    app.use(applicationErrorHandler)
  })

  it('get / for empty database should return an empty array', async () => {
    res = await chai.request(app).get('/')

    expect(res).to.be.json
    expect(res).to.have.status(200)
    expect(res.body).to.have.lengthOf(0)
  })

  it('get / should list all items in database', async () => {
    await collection.save({ title: 'a name' })
    await collection.save({ title: 'another one' })

    res = await chai.request(app).get('/')

    expect(res).to.be.json
    expect(res).to.have.status(200)
    const result = await collection.find()
    expect(res.body).to.be.eql(result.entities)
  })

  it('should support saving an entry', async () => {
    const res = await chai.request(app).post('/').send({ title: 'name' })
    const result = await collection.find()
    expect(res.body).to.be.eql(result.entities[0])
  })

  it('post / gives 422 on invalid entry', async () => {
    const res = await allowErrorResponse([422], chai.request(app).post('/').send({ name: 'name' }))
    expect(res).to.have.status(422)
    expect(res.text).to.not.be.undefined
  })

  it('snould support deleting an item', async () => {
    const res = await chai.request(app).post('/').send({ title: 'item to delete' })

    await chai.request(app).delete(`/${res.body.key}`)

    const result = await collection.find()
    expect(result.entities).to.be.empty
  })

  it('should support updating an item', async () => {
  })
})
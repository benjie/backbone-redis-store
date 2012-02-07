redisClient = require './redis_client'
Backbone = require 'backbone'
RedisStore = require './backbone-redis-store'
RedisStore.infect Backbone

class Test extends Backbone.Model
  test: null

class TestCollection extends Backbone.Collection
  redisStorage: new RedisStore
    key: 'test'
    redisClient: redisClient
    unique: ['test']
  model: Test

testCollection = new TestCollection()
testCollection.getByUnique 'test', '21',
  success: (model) ->
    if model
      console.log "Got it: "
      console.dir model
      fetchAll()
    else
      console.log "Couldn't find model"
  error: (err) ->
    console.dir err
fetchAll = ->
  testCollection.fetch
    success: ->
      console.log "Loaded #{testCollection.length} records."

      res = testCollection.get 1
      if res
        console.log "Loaded record 1: "
        console.dir res.toJSON()
      else
        console.error "Record 1 not found."

      testCollection.create {"test":testCollection.length+(parseInt(Math.random()*2))},
        success: (res) ->
          console.log "Created new record: "
          console.dir res.toJSON()

        error: (model,err) ->
          console.log "ERROR: "
          console.dir err
          throw err
    error: (e) ->
      console.error e
      process.exit 1


redisClient = require './redis_client'
Backbone = require 'backbone'
RedisStore = require './backbone-redis-store'
RedisStore.infect Backbone

class Test extends Backbone.Model
  test: null

class TestCollection extends Backbone.Collection
  redisStorage: new RedisStore('test',redisClient)
  model: Test

testCollection = new TestCollection()
testCollection.fetch
  success: ->
    console.log "Loaded #{testCollection.length} records."

    res = testCollection.get 1
    if res
      console.log "Loaded record 1: "
      console.dir res.toJSON()
    else
      console.error "Record 1 not found."

    testCollection.create {"test":Math.random()}, 
      success: (res) ->
        console.log "Created new record: "
        console.dir res.toJSON()

      error: (e) ->
        throw err
  error: (e) ->
    console.error e
    process.exit 1



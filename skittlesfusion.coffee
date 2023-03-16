fs = require 'fs'
http = require 'http'
https = require 'https'

config = {}

sleep = (ms) ->
  return new Promise (resolve, reject) ->
    setTimeout ->
      resolve(ms)
    , ms

poboxPull = (box) ->
  return new Promise (resolve, reject) ->
    req = https.request {
      host: config.host,
      path: "/pull/#{box}/#{config.secret}",
      port: '443',
      method: 'GET'
    }, (response) ->
      str = ''
      response.on 'data', (chunk) ->
        str += chunk
      response.on 'end', ->
        data = null
        try
          data = JSON.parse(str)
        catch
          console.log "Bad JSON: #{str}"
          data = []
        resolve(data)
    req.end()

poboxPush = (box, data) ->
  return new Promise (resolve, reject) ->
    req = https.request {
      host: config.host,
      path: "/push/#{box}/#{config.secret}",
      port: '443',
      method: 'POST'
      headers:
        'Content-Type': 'application/json'
    }, (response) ->
      str = ''
      response.on 'data', (chunk) ->
        str += chunk
      response.on 'end', ->
        resolve(true)
    req.write(JSON.stringify(data))
    req.end()

setModel = (model) ->
  return new Promise (resolve, reject) ->
    req = http.request {
      host: "127.0.0.1",
      path: "/sdapi/v1/options",
      port: '7860',
      method: 'POST'
      headers:
        'Content-Type': 'application/json'
    }, (response) ->
      str = ''
      response.on 'data', (chunk) ->
        str += chunk
      response.on 'end', ->
        resolve(true)
    req.write(JSON.stringify({
      "sd_model_checkpoint": model
    }))
    req.end()

txt2img = (prompt) ->
  return new Promise (resolve, reject) ->
    req = http.request {
      host: "127.0.0.1",
      path: "/sdapi/v1/txt2img",
      port: '7860',
      method: 'POST'
      headers:
        'Content-Type': 'application/json'
    }, (response) ->
      str = ''
      response.on 'data', (chunk) ->
        str += chunk
      response.on 'end', ->
        data = null
        try
          data = JSON.parse(str)
        catch
          console.log "Bad JSON: #{str}"
          data = []
        resolve(data)
    req.write(JSON.stringify({
      "prompt": prompt
      "seed": -1
      "batch_size": 1
      "n_iter": 1
      "steps": 25
      "cfg_scale": 7
      "width": 512
      "height": 512
    }))
    req.end()

diffusion = (req) ->
  console.log "Configuring model: #{req.model}"
  await setModel(req.model)

  console.log "txt2img: #{req.prompt}"
  result = await txt2img(req.prompt)
  message = {
    channel: req.channel
    tag: req.tag
  }

  if result? and result.images? and result.images.length > 0
    message.text = "Complete: [#{req.model}] #{req.prompt}"
    message.image = result.images[0]
  else
    message.text = "**FAILED**: [#{req.model}] #{req.prompt}"

  console.log "Replying: [#{message.channel}][#{message.tag}][#{message.text}][#{message.image?.length}]"
  await poboxPush 'skittles', message
main = ->
  config = JSON.parse(fs.readFileSync("skittlesfusion.json", "utf8"))
  console.log config

  loop
    box = await poboxPull('diffusion')
    for req in box
      console.log "Processing: ", req
      await diffusion(req)

    await sleep(5000)

main()

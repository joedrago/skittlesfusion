fs = require 'fs'
http = require 'http'
https = require 'https'
PNG = require('pngjs').PNG

config = {}

sleep = (ms) ->
  return new Promise (resolve, reject) ->
    setTimeout ->
      resolve(ms)
    , ms

downloadUrl = (url) ->
  return new Promise (resolve, reject) ->
    req = https.request url, {
      method: 'GET'
    }, (response) ->
      chunks = []
      response.on 'data', (chunk) ->
        chunks.push chunk
      response.on 'end', ->
        buffer = Buffer.concat(chunks)
        resolve(buffer)
      response.on 'error', ->
        resolve(null)
    req.end()

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

img2img = (imageBuffer, prompt) ->
  return new Promise (resolve, reject) ->
    denoisingStrength = 0.5
    if matches = prompt.match(/^\[([^\]]+)\]\s+(.*)/)
      denoisingStrength = parseFloat(matches[1])
      prompt = matches[2]
    console.log "denoisingStrength: #{denoisingStrength}, prompt \"#{prompt}\""

    png = PNG.sync.read(imageBuffer)
    pngAspect = png.width / png.height
    if pngAspect < 1
      imageHeight = 512
      imageWidth = Math.floor(imageHeight * pngAspect / 4) * 4
    else
      imageWidth = 512
      imageHeight = Math.floor(imageWidth / pngAspect / 4) * 4

    req = http.request {
      host: "127.0.0.1",
      path: "/sdapi/v1/img2img",
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
      "init_images": [
        "data:image/png;base64," + imageBuffer.toString('base64')
      ]
      "include_init_images": true
      "denoising_strength": denoisingStrength
      "prompt": prompt
      "seed": -1
      "steps": 40
      "cfg_scale": 7
      "width": imageWidth
      "height": imageHeight
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
      "steps": 40
      "cfg_scale": 7
      "width": 512
      "height": 512
    }))
    req.end()

diffusion = (req) ->
  imageBuffer = null
  if req.image?
    imageBuffer = await downloadUrl(req.image)
    console.log "imageBuffer[#{imageBuffer.length}]: #{req.image}"

  console.log "Configuring model: #{req.model}"
  await setModel(req.model)

  if imageBuffer?
    console.log "img2img[#{imageBuffer.length}]: #{req.prompt}"
    fs.writeFileSync("curious.html", "<img src=\"data:image/png;base64," + imageBuffer.toString('base64') + "\">")
    result = await img2img(imageBuffer, req.prompt)
  else
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

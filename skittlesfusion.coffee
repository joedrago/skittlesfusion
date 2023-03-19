fs = require 'fs'
http = require 'http'
https = require 'https'
path = require 'path'
PNG = require('pngjs').PNG
JPEG = require 'jpeg-js'

config = {}

paramAliases =
  denoise: "denoising_strength"
  denoising: "denoising_strength"
  dns: "denoising_strength"
  dn: "denoising_strength"
  noise: "denoising_strength"
  de: "denoising_strength"
  cfg: "cfg_scale"
  step: "steps"
  w: "width"
  h: "height"
  sampler: "sampler_name"
  samp: "sampler_name"
  count: "batch_size"
  batch: "batch_size"

paramConfig =
  width:
    description: "Output image width"
    default: 512
    min: 128
    max: 1024
  height:
    description: "Output image height"
    default: 512
    min: 128
    max: 1024
  steps:
    description: "How many times to re-run the model on the output image"
    default: 40
    min: 1
    max: 100
  cfg_scale:
    description: "Classifier Free Guidance scale: How strongly the image should conform to the prompt"
    default: 7
    min: 1
    max: 30
  denoising_strength:
    description: "How closely to match the input image. Low numbers match the image strongly, high numbers throw most of it away"
    default: 0.5
    min: 0.0
    max: 1.0
    float: true
  seed:
    description: "Random seed. Leave at -1 to keep it random, or use the previous seed to recreate the last image"
    default: -1
    min: -1
    max: 2147483647
  batch_size:
    description: "How many images to generate"
    default: 1
    min: 1
    max: 9
  sampler_name:
    description: "Which sampler to use. No, I don't understand it either."
    default: "DPM++ 2M Karras"
    enum: [
      "DDIM"
      "DPM adaptive"
      "DPM fast"
      "DPM++ 2M Karras"
      "DPM++ 2M"
      "DPM++ 2S a Karras"
      "DPM++ 2S a"
      "DPM++ SDE Karras"
      "DPM++ SDE"
      "DPM2 a Karras"
      "DPM2 a"
      "DPM2 Karras"
      "DPM2"
      "Euler a"
      "Euler"
      "Heun"
      "LMS Karras"
      "LMS"
      "PLMS"
    ]

parseParams = (prompt) ->
  rawParams = ""
  if matches = prompt.match(/^\[([^\]]+)\](.*)/)
    rawParams = matches[1]
    prompt = matches[2]
    prompt = prompt.replace(/^[, ]+/, "")

  posNeg = prompt.split(/\|\|/)
  if posNeg.length > 1
    params =
      prompt: posNeg[0].trim()
      negative_prompt: posNeg[1].trim()
  else
    params =
      prompt: prompt

  for name,pc of paramConfig
    params[name] = pc.default
  # console.log params

  keyName = "denoising_strength"
  pieces = rawParams.split(/[:,\s]+/)
  # console.log pieces
  for piece in pieces
    v = parseFloat(piece)
    if keyName? and not isNaN(v)
      if paramConfig[keyName].enum?
        v = Math.round(v)
        if (v < 0) or (v > paramConfig[keyName].enum.length - 1)
          v = 0
        v = paramConfig[keyName].enum[v]
      else
        if paramConfig[keyName].min? and v < paramConfig[keyName].min
          v = paramConfig[keyName].min
        if paramConfig[keyName].max? and v > paramConfig[keyName].max
          v = paramConfig[keyName].max
        if not paramConfig[keyName].float
          v = Math.round(v)
      params[keyName] = v
      keyName = null
    else
      keyName = piece.toLowerCase()
      if paramAliases[keyName]?
        keyName = paramAliases[keyName]
      if not paramConfig[keyName]?
        keyName = null

  return params

pad = (s, count) ->
  return ("                   " + s).slice(-1 * count)

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
      response.on 'error', (e) ->
        console.log "Response Error: ", e
    jsonData = JSON.stringify(data)
    req.on 'error', (e) ->
      console.log "Request Error: ", e
    console.log "poboxPush invoked! posting with #{jsonData.length} bytes"
    req.write(jsonData)
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

img2img = (imageType, imageBuffer, prompt) ->
  return new Promise (resolve, reject) ->
    params = parseParams(prompt)

    if imageType == 'image/png'
      png = PNG.sync.read(imageBuffer)
      imageWidth = png.width
      imageHeight = png.height
    else
      # jpeg
      rawjpeg = JPEG.decode(imageBuffer)
      imageWidth = rawjpeg.width
      imageHeight = rawjpeg.height

    imageAspect = imageWidth / imageHeight
    console.log "Decoded image [#{imageType}] #{imageWidth}x#{imageHeight} (#{imageAspect})"
    if imageAspect < 1
      params.height = Math.floor(params.height / 4) * 4
      params.width = Math.floor(params.height * imageAspect / 4) * 4
    else
      params.width = Math.floor(params.width / 4) * 4
      params.height = Math.floor(params.width / imageAspect / 4) * 4


    params.include_init_images = true
    console.log "Params: ", params
    params.init_images = [
      "data:image/png;base64," + imageBuffer.toString('base64')
    ]

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
          delete params["init_images"]
          delete params["include_init_images"]
          data.skittlesparams = params
        catch
          console.log "Bad JSON: #{str}"
          data = []
        resolve(data)

    req.write(JSON.stringify(params))
    req.end()

txt2img = (prompt) ->
  return new Promise (resolve, reject) ->
    params = parseParams(prompt)
    params.width = Math.floor(params.width / 4) * 4
    params.height = Math.floor(params.height / 4) * 4
    console.log "Params: ", params

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
          data.skittlesparams = params
        catch
          console.log "Bad JSON: #{str}"
          data = []
        resolve(data)

    req.write(JSON.stringify(params))
    req.end()

diffusion = (req) ->
  imageType = 'image/png'
  imageBuffer = null
  if req.image?
    url = new URL(req.image)
    pieces = path.parse(url.pathname)
    if (pieces.ext == '.jpg') or (pieces.ext == '.jpeg')
      imageType = 'image/jpeg'
    console.log "imageType: #{imageType}"
    imageBuffer = await downloadUrl(req.image)
    console.log "imageBuffer[#{imageBuffer.length}][#{imageType}]: #{req.image}"

  console.log "Configuring model: #{req.model}"
  await setModel(req.model)

  message = {
    channel: req.channel
    tag: req.tag
  }
  message.text = "Started [#{req.model}]"
  await poboxPush 'skittles', message

  startTime = +new Date()
  if imageBuffer?
    console.log "img2img[#{imageBuffer.length}]: #{req.prompt}"
    # fs.writeFileSync("curious.html", "<img src=\"data:#{imageType};base64," + imageBuffer.toString('base64') + "\">")
    result = await img2img(imageType, imageBuffer, req.prompt)
  else
    console.log "txt2img: #{req.prompt}"
    result = await txt2img(req.prompt)
  endTime = +new Date()
  timeTaken = endTime - startTime

  try
    outputSeed = JSON.parse(result.info).seed
  catch
    console.log "naw"
    outputSeed = -1

  result.skittlesparams.seed = outputSeed

  if result? and result.images? and result.images.length > 0
    console.log "Received #{result.images.length} images..."
    message.text = "Complete [#{req.model}][#{(timeTaken/1000).toFixed(2)}s]: `#{JSON.stringify(result.skittlesparams)}`\n"
    message.images = result.images
  else
    message.text = "**FAILED**: [#{req.model}] #{req.prompt}"

  console.log "Replying: [#{message.channel}][#{message.tag}][#{message.text}][#{message.image?.length}]"
  await poboxPush 'skittles', message
  console.log "Reply complete."

queryConfig = (req) ->
  message = {
    channel: req.channel
    tag: req.tag
  }

  o = "```\n"
  o += "Skittles SD Worker Config\n";
  o += "-------------------------\n";

  for pcName, pc of paramConfig
    pcAliases = []
    for paName, pa of paramAliases
      if pcName == pa
        pcAliases.push paName

    o += "\n* #{pcName} - #{pc.description}\n"
    if pcAliases.length > 0
      o += "  Aliases: #{pcAliases.join(', ')}\n"
    o += "  Default: #{pc.default}\n"
    if pc.enum?
      o += "  Choices: (supply the number)\n"
      for pcChoice, pcChoiceIndex in pc.enum
        o += "    #{pad(pcChoiceIndex, 2)}: #{pcChoice}\n"
    else if pc.min? and pc.max?
      if pc.float?
        o += "  Range  : [#{pc.min.toFixed(1)}, #{pc.max.toFixed(1)}]\n"
      else
        o += "  Range  : [#{pc.min}, #{pc.max}]\n"

  o += "```"
  #```\n#{JSON.stringify(paramAliases, null, 2)}\n#{JSON.stringify(paramConfig, null, 2)}\n```"

  message.text = o

  console.log "Config Replying: [#{message.channel}][#{message.tag}][#{message.text.length}]"
  await poboxPush 'skittles', message
  console.log "Config Reply complete."

main = ->
  config = JSON.parse(fs.readFileSync("skittlesfusion.json", "utf8"))
  console.log config

  loop
    try
      box = await poboxPull('diffusion')
    catch e
      console.log "poboxPull ate itself, waiting 5 seconds:", e
      await sleep(5000)
      continue
    for req in box
      console.log "Processing: ", req
      if req.config?
        await queryConfig(req)
      else
        await diffusion(req)

    await sleep(5000)

main()

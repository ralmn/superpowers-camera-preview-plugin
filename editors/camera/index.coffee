qs = require('querystring').parse window.location.search.slice(1)
info = { projectId: qs.project, assetId: qs.asset }
data = null
async = require 'async'
THREE = SupEngine.THREE
TransformMarker = require './TransformMarker'

ui = {bySceneNodeId: {}}
socket = null
cameraPreviewSubscriber = {}
entriesSubscriber = {}

start = ->

  socket = SupClient.connect info.projectId
  socket.on 'connect', onConnected
  socket.on 'disconnect', SupClient.onDisconnected
  socket.on 'edit:assets', onAssetEdited
  socket.on 'trash:assets', SupClient.onAssetTrashed


  @sceneElm = document.querySelector("#scene-select")
  @canvasElt = document.querySelector('canvas')

  @sceneElm.addEventListener 'change', onSceneChange.bind(@)

  ui.gameInstance = new SupEngine.GameInstance @canvasElt

  entriesSubscriber.onEntriesReceived = _onEntriesReceived.bind(@)
  cameraPreviewSubscriber.onAssetReceived = _onAssetReceived.bind(@)
  cameraPreviewSubscriber.onAssetEdited = onAssetEdited.bind @
  cameraPreviewSubscriber.onAssetTrashed = () -> return
  ui.tickAnimationFrameId = requestAnimationFrame tick
  return


# Network callbacks
onConnected = ->

  data = projectClient: new SupClient.ProjectClient socket, { subEntries: true }
  data.projectClient.subEntries entriesSubscriber
  #socket.emit 'sub', 'assets', info.assetId, onAssetReceived
  return

_onEntriesReceived = (entries) ->
  walk = (entry, parent) ->
    if parent?
      fullName = parent + "/" +entry.name
    else
      fullName = entry.name
    if entry?.type == "scene"
        option = document.createElement "option"
        option.value = fullName
        option.textContent = fullName
        @sceneElm.appendChild option
    if entry.children? and entry.children.length > 0
      walk child, fullName for child in entry.children
  walk entry, null for entry in entries.pub

  onSceneChange()



onAssetReceived = (err, asset) ->

onAssetEdited = (id, command, args...) ->
  onAssetCommands[command]?.apply data.asset, args
  return


onSceneChange = () ->
  ui.gameInstance.destroyAllActors()
  sceneName = @sceneElm.value
  entry = SupClient.findEntryByPath data.projectClient.entries.pub, sceneName
  if entry?
    data.projectClient.sub entry.id, 'scene', cameraPreviewSubscriber
  return

createNodeActor = (node) ->
  parentNode = data.asset.nodes.parentNodesById[node.id]
  parentActor = ui.bySceneNodeId[parentNode.id].actor if parentNode?

  nodeActor = new SupEngine.Actor ui.gameInstance, node.name, parentActor
  nodeActor.threeObject.position.copy node.position
  nodeActor.threeObject.quaternion.copy node.orientation
  nodeActor.threeObject.scale.copy node.scale
  nodeActor.threeObject.updateMatrixWorld()

  ui.bySceneNodeId[node.id] = { actor: nodeActor, bySceneComponentId: {} }

  for component in node.components
    createNodeActorComponent node, component, nodeActor

  nodeActor

setupsCompopent = {}

createNodeActorComponent = (sceneNode, sceneComponent, nodeActor) ->
  if ui.bySceneNodeId[sceneNode.id]?.bySceneComponentId[sceneComponent.id]?
    return

  return if sceneComponent.type in ['Behavior', 'ArcadeBody2D']

  componentClass = SupEngine.componentPlugins[sceneComponent.type]
  #componentClass = SupEngine.editorComponents["#{sceneComponent.type}Marker"] ? SupEngine.componentPlugins[sceneComponent.type]

  return if !componentClass?

  actorComponent = new componentClass nodeActor
  componentUpdater = null
  if componentClass.Updater
    componentUpdater = new componentClass.Updater data.projectClient, actorComponent, sceneComponent.config
  else
    if setupsCompopent["#{sceneComponent.type}Component"]?
      setupsCompopent["#{sceneComponent.type}Component"] actorComponent, sceneComponent.config

  ui.bySceneNodeId[sceneNode.id].bySceneComponentId[sceneComponent.id] =
    component: actorComponent
    componentUpdater: componentUpdater

  return

onAssetCommands = {}

setupsCompopent.CameraComponent = (cameraComponent, config) =>
  cameraComponent.setOrthographicMode config.mode == "orthographic" if config.mode?
  cameraComponent.setOrthographicScale config.orthographicScale if config.orthographicScale?
  cameraComponent.setFOV config.FOV if config.fov?
  cameraComponent.setViewport config.viewport.x, config.viewport.y, config.viewport.width, config.viewport.height if config.viewport?
  return

setupsCompopent.CameraComponentPropertyEdited = (cameraComponent, name, value) =>
  switch name
    when "mode"
      cameraComponent.setOrthographicMode value == "orthographic"
    when "fov"
      cameraComponent.setFOV value
    when "orthographicScale"
      cameraComponent.setOrthographicScale value
  return

onAssetCommands.setComponentProperty = (nodeId, componentId, path, value) ->
  componentData = ui.bySceneNodeId[nodeId].bySceneComponentId[componentId]
  componentUpdater = componentData.componentUpdater
  if componentUpdate?
    componentUpdater.onConfigEdited path, value if componentUpdater?
  else
    if setupsCompopent["#{componentData.component.typeName}ComponentPropertyEdited"]?
      newComponent = setupsCompopent["#{componentData.component.typeName}ComponentPropertyEdited"] componentData.component, path, value
  return

onAssetCommands.setNodeProperty = (id, path, value) ->
  switch path
    when 'position'
      ui.bySceneNodeId[id].actor.setLocalPosition value
    when 'orientation'
      ui.bySceneNodeId[id].actor.setLocalOrientation value
    when 'scale'
      ui.bySceneNodeId[id].actor.setLocalScale value

  return

onAssetCommands.addNode = (node, parentId, index) ->
  createNodeActor node
  return

onAssetCommands.duplicateNode = (rootNode, newNodes) ->
  for newNode in newNodes
    onAssetCommands.addNode newNode.node, newNode.parentId, newNode.index
  return

onAssetCommands.removeNode = (id) ->
  ui.gameInstance.destroyActor ui.bySceneNodeId[id].actor if ui.bySceneNodeId[id]?
  delete ui.bySceneNodeId[id]  if ui.bySceneNodeId[id]?
  return

onAssetCommands.removeComponent = (nodeId, componentId) ->
  if ui.bySceneNodeId[nodeId]?.bySceneComponentId[componentId]?
    ui.gameInstance.destroyComponent ui.bySceneNodeId[nodeId]?.bySceneComponentId[componentId]?.component
    delete ui.bySceneNodeId[nodeId].bySceneComponentId[componentId]
  return


onAssetCommands.addComponent = (nodeId, nodeComponent, index) ->
  createNodeActorComponent data.asset.nodes.byId[nodeId], nodeComponent, ui.bySceneNodeId[nodeId].actor
  return

_onAssetReceived = (assetId, asset) ->
  data.asset = asset

  walk = (node) ->
    actor = createNodeActor node
    if node.components.length > 0
      for component in node.components
        createNodeActorComponent node, component, actor

    if node.children? and node.children.length > 0
      walk child for child in node.children
    return
  walk node, null, null for node in data.asset.nodes.pub
  ui.tickAnimationFrameId = requestAnimationFrame tick
  return

tick = ->
  # FIXME: decouple update interval from render interval
  ui.gameInstance.update()
  ui.gameInstance.draw()
  ui.tickAnimationFrameId = requestAnimationFrame tick


async.each SupClient.pluginPaths.all, (pluginName, pluginCallback) ->
  if pluginName == "ralmn/superpowers-camera-preview-plugin" then pluginCallback(); return

  async.series [

    (cb) ->
      dataScript = document.createElement('script')
      dataScript.src = "/plugins/#{pluginName}/data.js"
      dataScript.addEventListener 'load', -> cb()
      dataScript.addEventListener 'error', -> cb()
      document.body.appendChild dataScript

    (cb) ->
      componentsScript = document.createElement('script')
      componentsScript.src = "/plugins/#{pluginName}/components.js"
      componentsScript.addEventListener 'load', -> cb()
      componentsScript.addEventListener 'error', -> cb()
      document.body.appendChild componentsScript

    (cb) ->
      componentEditorsScript = document.createElement('script')
      componentEditorsScript.src = "/plugins/#{pluginName}/componentEditors.js"
      componentEditorsScript.addEventListener 'load', -> cb()
      componentEditorsScript.addEventListener 'error', -> cb()
      document.body.appendChild componentEditorsScript
    # (cb) ->
    #   componentEditorsScript = document.createElement('script')
    #   componentEditorsScript.src = "/plugins/#{pluginName}/runtime.js"
    #   componentEditorsScript.addEventListener 'load', -> cb()
    #   componentEditorsScript.addEventListener 'error', -> cb()
    #   document.body.appendChild componentEditorsScript

  ], pluginCallback
, (err) ->
# Start
start()


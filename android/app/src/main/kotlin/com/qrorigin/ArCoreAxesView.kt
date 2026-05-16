package com.qrorigin

import android.content.Context
import android.graphics.BitmapFactory
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.view.View
import com.google.ar.core.*
import com.google.ar.core.exceptions.*
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

/**
 * Native ARCore view — Flow 1 + Flow 2 (Phase 1 & 2).
 *
 * Flow 2 additions:
 * - Phase 1: VIO delta tracking — render axes/nodes even when QR not visible
 *   by using the locked origin pose in ARCore's stable world frame.
 * - Phase 2: Environmental anchors — create anchors near QR after lock,
 *   use them to detect drift and provide correction observations.
 */
class ArCoreAxesView(
    private val context: Context,
    private val messenger: BinaryMessenger,
    private val viewId: Int,
) : PlatformView, GLSurfaceView.Renderer {

    private val glView: GLSurfaceView = GLSurfaceView(context)
    private var session: Session? = null
    private var axesRenderer: AxesRenderer? = null
    private var backgroundRenderer: BackgroundRenderer? = null

    private val channel = MethodChannel(messenger, "qr_origin/ar_view_$viewId")

    // ========== Flow 2 Phase 1: VIO Delta Tracking ==========
    // Once QR is detected, we lock its world pose. ARCore's VIO keeps the
    // world frame stable, so we can render at this pose indefinitely.
    private var originLocked = false
    private var lockedOriginMatrix = FloatArray(16) // 4x4 model matrix of QR origin
    private var lockedOriginPose: Pose? = null      // Pose object for anchor creation

    // Track whether QR is currently visible this frame
    private var qrVisibleThisFrame = false

    // Track camera movement for confidence decay
    private var lastCameraPosition = FloatArray(3)
    private var accumulatedPathLength = 0f
    private var lastAnchorObservationMs = 0L

    // ========== Flow 2 Phase 2: Environmental Anchors ==========
    data class EnvironmentalAnchor(
        val anchor: Anchor,
        val relativeToOrigin: FloatArray, // 4x4 matrix: how to get from this anchor to origin
        val label: String,
    )

    private val envAnchors = mutableListOf<EnvironmentalAnchor>()
    private var anchorsCreated = false
    private val MAX_ENV_ANCHORS = 5

    // ========== Node Management ==========
    data class NodeData(
        val id: String,
        var name: String,
        var selected: Boolean = false,
        var x: Float = 0f,
        var y: Float = 0f,
        var z: Float = 0f,
    )

    private val nodes = mutableListOf<NodeData>()
    private var lastCameraRelativeX = 0f
    private var lastCameraRelativeY = 0f
    private var lastCameraRelativeZ = 0f

    // ========== Confidence ==========
    private var confidenceScore = 0f

    // ========== Flow 2 Phase 3: Smooth Correction ==========
    // When anchor re-observed, compute correction and lerp over 25 frames
    private var correctionTarget: FloatArray? = null  // target origin matrix
    private var correctionFramesRemaining = 0
    private val CORRECTION_FRAMES = 25  // ~0.8 seconds at 30fps

    // ========== Flow 2 Phase 4: Dead Reckoning Ceiling ==========
    private val DEAD_RECKONING_LIMIT_MS = 90_000L  // 90 seconds
    private var isFrozen = false
    private var lastConfidenceSentToFlutter = -1f
    private var frameCounter = 0

    init {
        glView.preserveEGLContextOnPause = true
        glView.setEGLContextClientVersion(2)
        glView.setEGLConfigChooser(8, 8, 8, 8, 16, 0)
        glView.setRenderer(this)
        glView.renderMode = GLSurfaceView.RENDERMODE_CONTINUOUSLY
        glView.onResume()

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "addNode" -> {
                    val id = call.argument<String>("id") ?: ""
                    val name = call.argument<String>("name") ?: ""
                    val x = call.argument<Double>("x")?.toFloat()
                    val y = call.argument<Double>("y")?.toFloat()
                    val z = call.argument<Double>("z")?.toFloat()
                    if (x != null && y != null && z != null) {
                        // Load node at specific position (from saved map)
                        addNodeAtPosition(id, name, x, y, z)
                    } else {
                        // Place at current camera position
                        addNodeSphere(id, name)
                    }
                    result.success(null)
                }
                "selectNode" -> {
                    val id = call.argument<String>("id") ?: ""
                    selectNodeById(id)
                    result.success(null)
                }
                "deleteNode" -> {
                    val id = call.argument<String>("id") ?: ""
                    deleteNodeById(id)
                    result.success(null)
                }
                "renameNode" -> {
                    val id = call.argument<String>("id") ?: ""
                    val name = call.argument<String>("name") ?: ""
                    renameNodeById(id, name)
                    result.success(null)
                }
                "getNodePositions" -> {
                    val positions = mutableMapOf<String, Map<String, Float>>()
                    for (node in nodes) {
                        positions[node.id] = mapOf("x" to node.x, "y" to node.y, "z" to node.z)
                    }
                    result.success(positions)
                }
                "dispose" -> {
                    session?.close()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    // --- Node Management ---

    private fun addNodeSphere(id: String, name: String) {
        val node = NodeData(
            id = id, name = name, selected = true,
            x = lastCameraRelativeX,
            y = lastCameraRelativeY,
            z = lastCameraRelativeZ,
        )
        nodes.forEach { it.selected = false }
        nodes.add(node)
        android.util.Log.d("ArCoreAxes", "Node added at camera pos (${node.x}, ${node.y}, ${node.z})")
    }

    private fun addNodeAtPosition(id: String, name: String, x: Float, y: Float, z: Float) {
        val node = NodeData(id = id, name = name, selected = false, x = x, y = y, z = z)
        nodes.add(node)
        android.util.Log.d("ArCoreAxes", "Node loaded at (${x}, ${y}, ${z})")
    }

    private fun selectNodeById(id: String) {
        nodes.forEach { it.selected = (it.id == id) }
    }

    private fun deleteNodeById(id: String) {
        nodes.removeAll { it.id == id }
    }

    private fun renameNodeById(id: String, name: String) {
        nodes.find { it.id == id }?.name = name
    }

    // ========== Multi-Anchor QR Config ==========
    data class QrAnchorConfig(
        val id: String,
        val isPrimary: Boolean,
        val posX: Float, val posY: Float, val posZ: Float,
        val rotX: Float, val rotY: Float, val rotZ: Float, val rotW: Float,
        val physicalSize: Float,
        val label: String,
    )

    private val anchorConfigs = mutableListOf<QrAnchorConfig>()

    override fun getView(): View = glView

    override fun dispose() {
        envAnchors.forEach { it.anchor.detach() }
        envAnchors.clear()
        session?.close()
        session = null
    }

    // ========== GLSurfaceView.Renderer ==========

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        GLES20.glClearColor(0f, 0f, 0f, 1f)

        try {
            // Load multi-anchor config
            loadAnchorConfig()

            session = Session(context).also { sess ->
                val arConfig = Config(sess).apply {
                    updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
                    focusMode = Config.FocusMode.AUTO
                    planeFindingMode = Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL
                }

                // Load ALL QR images into ARCore database
                val imageDatabase = AugmentedImageDatabase(sess)
                for (anchorCfg in anchorConfigs) {
                    try {
                        val path = "flutter_assets/assets/qr_anchors/${anchorCfg.id}.jpg"
                        val inputStream = context.assets.open(path)
                        val bitmap = BitmapFactory.decodeStream(inputStream)
                        inputStream.close()
                        if (bitmap != null) {
                            imageDatabase.addImage(anchorCfg.id, bitmap, anchorCfg.physicalSize)
                            android.util.Log.d("ArCoreAxes",
                                "Loaded QR '${anchorCfg.id}' (${anchorCfg.label})")
                        }
                    } catch (e: Exception) {
                        android.util.Log.w("ArCoreAxes",
                            "Failed to load QR ${anchorCfg.id}: ${e.message}")
                    }
                }
                android.util.Log.d("ArCoreAxes",
                    "Image database: ${anchorConfigs.size} QR codes loaded")

                arConfig.augmentedImageDatabase = imageDatabase
                sess.configure(arConfig)
                sess.resume()
            }

            backgroundRenderer = BackgroundRenderer()
            backgroundRenderer?.createOnGlThread(context)
            axesRenderer = AxesRenderer()
            axesRenderer?.createOnGlThread()

        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        GLES20.glViewport(0, 0, width, height)
        session?.setDisplayGeometry(0, width, height)
    }

    override fun onDrawFrame(gl: GL10?) {
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT or GLES20.GL_DEPTH_BUFFER_BIT)

        val sess = session ?: return

        try {
            sess.setCameraTextureName(backgroundRenderer?.textureId ?: return)
            val frame: Frame
            try {
                frame = sess.update()
            } catch (e: SessionPausedException) { return }
            catch (e: CameraNotAvailableException) { return }

            val camera = frame.camera
            backgroundRenderer?.draw(frame)

            if (camera.trackingState != TrackingState.TRACKING) return

            val projMatrix = FloatArray(16)
            camera.getProjectionMatrix(projMatrix, 0, 0.01f, 100f)
            val viewMatrix = FloatArray(16)
            camera.getViewMatrix(viewMatrix, 0)

            // Track camera movement for path length
            val camPos = camera.pose.let { floatArrayOf(it.tx(), it.ty(), it.tz()) }
            if (originLocked) {
                val dx = camPos[0] - lastCameraPosition[0]
                val dy = camPos[1] - lastCameraPosition[1]
                val dz = camPos[2] - lastCameraPosition[2]
                val dist = Math.sqrt((dx * dx + dy * dy + dz * dz).toDouble()).toFloat()
                if (dist < 1.0f) { // ignore teleports
                    accumulatedPathLength += dist
                }
            }
            lastCameraPosition = camPos

            // --- Check augmented images (multi-anchor) ---
            qrVisibleThisFrame = false
            val images = frame.getUpdatedTrackables(AugmentedImage::class.java)
            for (image in images) {
                if (image.trackingState == TrackingState.TRACKING &&
                    image.trackingMethod == AugmentedImage.TrackingMethod.FULL_TRACKING) {

                    // Lookup config for this QR by name (name = ID set during addImage)
                    val cfg = anchorConfigs.find { it.id == image.name }
                    if (cfg == null) {
                        android.util.Log.w("ArCoreAxes", "Unknown QR detected: ${image.name}")
                        continue
                    }

                    qrVisibleThisFrame = true
                    val pose = image.centerPose
                    val modelMatrix = FloatArray(16)
                    pose.toMatrix(modelMatrix, 0)

                    // Compute where origin should be based on this QR
                    val observedOriginMatrix = computeOriginFromQr(modelMatrix, cfg)

                    // Phase 1: Lock origin on first detection (any QR)
                    if (!originLocked) {
                        if (cfg.isPrimary) {
                            // Primary QR — direct lock
                            lockedOriginMatrix = observedOriginMatrix
                            lockedOriginPose = pose
                            originLocked = true
                            lastAnchorObservationMs = System.currentTimeMillis()
                            android.util.Log.d("ArCoreAxes",
                                "Origin LOCKED via PRIMARY '${cfg.label}'")
                        } else {
                            // Secondary QR — can still establish origin
                            lockedOriginMatrix = observedOriginMatrix
                            lockedOriginPose = pose
                            originLocked = true
                            lastAnchorObservationMs = System.currentTimeMillis()
                            android.util.Log.d("ArCoreAxes",
                                "Origin LOCKED via SECONDARY '${cfg.label}' (primary not seen yet)")
                        }

                        glView.post {
                            channel.invokeMethod("onImageTracked", mapOf(
                                "name" to cfg.id,
                                "label" to cfg.label,
                                "isPrimary" to cfg.isPrimary,
                            ))
                        }
                    } else {
                        // Phase 5: QR re-observed — smooth correction
                        val dx = observedOriginMatrix[12] - lockedOriginMatrix[12]
                        val dy = observedOriginMatrix[13] - lockedOriginMatrix[13]
                        val dz = observedOriginMatrix[14] - lockedOriginMatrix[14]
                        val delta = Math.sqrt((dx*dx + dy*dy + dz*dz).toDouble()).toFloat()

                        if (delta < 0.001f) {
                            // < 1mm — snap
                            lockedOriginMatrix = observedOriginMatrix
                        } else if (delta < 0.5f) {
                            // 1mm–500mm — smooth correction
                            correctionTarget = observedOriginMatrix
                            correctionFramesRemaining = CORRECTION_FRAMES
                            android.util.Log.d("ArCoreAxes",
                                "Correction from '${cfg.label}': delta=${(delta*1000).toInt()}mm")
                        } else {
                            // > 500mm — snap (or reject if secondary with bad config)
                            if (cfg.isPrimary) {
                                lockedOriginMatrix = observedOriginMatrix
                                android.util.Log.w("ArCoreAxes",
                                    "LARGE correction from PRIMARY: ${(delta*1000).toInt()}mm — snapping")
                            } else {
                                // Secondary with large delta — might be misconfigured
                                android.util.Log.w("ArCoreAxes",
                                    "REJECTED correction from '${cfg.label}': delta=${(delta*1000).toInt()}mm (too large for secondary)")
                            }
                        }

                        lockedOriginPose = pose
                        lastAnchorObservationMs = System.currentTimeMillis()

                        // Unfreeze if was frozen
                        if (isFrozen) {
                            isFrozen = false
                            accumulatedPathLength = 0f
                            glView.post { channel.invokeMethod("onDeadReckoningFreeze", false) }
                        }
                    }

                    // Update camera relative position using full matrix inverse
                    // lockedOriginMatrix is the 4x4 transform of origin in world space
                    // camera relative = inverse(originMatrix) × cameraWorldMatrix
                    val invOrigin = FloatArray(16)
                    android.opengl.Matrix.invertM(invOrigin, 0, lockedOriginMatrix, 0)
                    val camMatrix = FloatArray(16)
                    camera.pose.toMatrix(camMatrix, 0)
                    val relMatrix = FloatArray(16)
                    android.opengl.Matrix.multiplyMM(relMatrix, 0, invOrigin, 0, camMatrix, 0)
                    lastCameraRelativeX = relMatrix[12]
                    lastCameraRelativeY = relMatrix[13]
                    lastCameraRelativeZ = relMatrix[14]

                    // Create environmental anchors after first lock
                    if (originLocked && !anchorsCreated) {
                        createEnvironmentalAnchors(sess, pose)
                        anchorsCreated = true
                    }
                }
            }

            // --- Phase 2: Check environmental anchors ---
            if (originLocked && !qrVisibleThisFrame) {
                checkEnvironmentalAnchors(camera)
            }

            // --- Phase 3: Apply smooth correction ---
            if (correctionTarget != null && !isFrozen) {
                applySmoothCorrection()
            }

            // --- Phase 4: Compute confidence + dead reckoning ---
            updateConfidence()

            // --- RENDER ---
            if (originLocked) {
                if (isFrozen) {
                    // Phase 6: When frozen, still render at last trusted position
                    // but with a dimmed/red tint to indicate staleness.
                    // The lockedOriginMatrix is NOT updated — frozen in place.
                    axesRenderer?.draw(viewMatrix, projMatrix, lockedOriginMatrix)

                    // Render nodes dimmed
                    for (node in nodes) {
                        val nodeMatrix = FloatArray(16)
                        android.opengl.Matrix.setIdentityM(nodeMatrix, 0)
                        android.opengl.Matrix.translateM(nodeMatrix, 0, node.x, node.y, node.z)
                        val combinedMatrix = FloatArray(16)
                        android.opengl.Matrix.multiplyMM(combinedMatrix, 0, lockedOriginMatrix, 0, nodeMatrix, 0)
                        // All nodes render as dim gray when frozen
                        axesRenderer?.drawSphere(viewMatrix, projMatrix, combinedMatrix,
                            floatArrayOf(0.5f, 0.5f, 0.5f, 0.5f), 0.012f)
                    }
                } else {
                    // Normal rendering
                    axesRenderer?.draw(viewMatrix, projMatrix, lockedOriginMatrix)

                    for (node in nodes) {
                        val nodeMatrix = FloatArray(16)
                        android.opengl.Matrix.setIdentityM(nodeMatrix, 0)
                        android.opengl.Matrix.translateM(nodeMatrix, 0, node.x, node.y, node.z)
                        val combinedMatrix = FloatArray(16)
                        android.opengl.Matrix.multiplyMM(combinedMatrix, 0, lockedOriginMatrix, 0, nodeMatrix, 0)
                        val color = if (node.selected) floatArrayOf(1f, 0f, 0f, 1f)
                                    else floatArrayOf(0f, 1f, 0f, 1f)
                        axesRenderer?.drawSphere(viewMatrix, projMatrix, combinedMatrix, color, 0.012f)
                    }

                    // Render environmental anchor indicators
                    for (envAnchor in envAnchors) {
                        if (envAnchor.anchor.trackingState == TrackingState.TRACKING) {
                            val anchorMatrix = FloatArray(16)
                            envAnchor.anchor.pose.toMatrix(anchorMatrix, 0)
                            axesRenderer?.drawSphere(viewMatrix, projMatrix, anchorMatrix,
                                floatArrayOf(1f, 1f, 0f, 0.6f), 0.008f)
                        }
                    }
                }

                // Update camera relative even when QR not visible
                // Phase 6: Don't update when frozen — position is unreliable
                if (!isFrozen && !qrVisibleThisFrame) {
                    val invOrigin = FloatArray(16)
                    android.opengl.Matrix.invertM(invOrigin, 0, lockedOriginMatrix, 0)
                    val camMatrix = FloatArray(16)
                    camera.pose.toMatrix(camMatrix, 0)
                    val relMatrix = FloatArray(16)
                    android.opengl.Matrix.multiplyMM(relMatrix, 0, invOrigin, 0, camMatrix, 0)
                    lastCameraRelativeX = relMatrix[12]
                    lastCameraRelativeY = relMatrix[13]
                    lastCameraRelativeZ = relMatrix[14]
                }
            }

        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    // ========== Phase 2: Environmental Anchors ==========

    /**
     * Create 5 anchors around the QR origin to serve as reference points.
     * These help detect and correct VIO drift when QR is not visible.
     *
     * Anchor positions (relative to QR center):
     * - 0.5m right (+X)
     * - 0.5m left (-X)
     * - 0.5m forward (+Z)
     * - 0.5m back (-Z)
     * - 0.3m up (+Y)
     */
    private fun createEnvironmentalAnchors(session: Session, qrPose: Pose) {
        val offsets = arrayOf(
            floatArrayOf(0.5f, 0f, 0f),    // right
            floatArrayOf(-0.5f, 0f, 0f),   // left
            floatArrayOf(0f, 0f, 0.5f),    // forward
            floatArrayOf(0f, 0f, -0.5f),   // back
            floatArrayOf(0f, 0.3f, 0f),    // up
        )
        val labels = arrayOf("Right", "Left", "Forward", "Back", "Up")

        for (i in offsets.indices) {
            try {
                // Create anchor at offset from QR
                val offset = offsets[i]
                val anchorPose = qrPose.compose(
                    Pose.makeTranslation(offset[0], offset[1], offset[2])
                )
                val anchor = session.createAnchor(anchorPose)

                // Compute how to get from anchor back to origin
                // relativeToOrigin = anchorPose.inverse() * qrPose
                val anchorInverse = anchorPose.inverse()
                val relMatrix = FloatArray(16)
                anchorInverse.compose(qrPose).toMatrix(relMatrix, 0)

                envAnchors.add(EnvironmentalAnchor(
                    anchor = anchor,
                    relativeToOrigin = relMatrix,
                    label = labels[i],
                ))

                android.util.Log.d("ArCoreAxes",
                    "Env anchor '${labels[i]}' created at offset (${offset[0]}, ${offset[1]}, ${offset[2]})")
            } catch (e: Exception) {
                android.util.Log.w("ArCoreAxes", "Failed to create anchor ${labels[i]}: ${e.message}")
            }
        }

        android.util.Log.d("ArCoreAxes", "Created ${envAnchors.size} environmental anchors")
    }

    /**
     * Phase 3: Check environmental anchors and compute smooth correction.
     * When an anchor is tracking, compute where origin SHOULD be,
     * then lerp towards that target over multiple frames.
     */
    private fun checkEnvironmentalAnchors(camera: Camera) {
        var anyTracking = false
        var bestObservedOrigin: FloatArray? = null

        for (envAnchor in envAnchors) {
            if (envAnchor.anchor.trackingState == TrackingState.TRACKING) {
                anyTracking = true

                // Compute where origin should be based on this anchor
                val anchorMatrix = FloatArray(16)
                envAnchor.anchor.pose.toMatrix(anchorMatrix, 0)

                val observedOriginMatrix = FloatArray(16)
                android.opengl.Matrix.multiplyMM(
                    observedOriginMatrix, 0,
                    anchorMatrix, 0,
                    envAnchor.relativeToOrigin, 0
                )

                // Use first valid observation (could average multiple later)
                if (bestObservedOrigin == null) {
                    bestObservedOrigin = observedOriginMatrix
                }

                lastAnchorObservationMs = System.currentTimeMillis()
            }
        }

        // Phase 3: Apply smooth correction if we have an observation
        if (bestObservedOrigin != null && !qrVisibleThisFrame) {
            // Compute delta between current locked and observed
            val dx = bestObservedOrigin[12] - lockedOriginMatrix[12]
            val dy = bestObservedOrigin[13] - lockedOriginMatrix[13]
            val dz = bestObservedOrigin[14] - lockedOriginMatrix[14]
            val delta = Math.sqrt((dx * dx + dy * dy + dz * dz).toDouble()).toFloat()

            // Only correct if delta is significant (> 2mm) but not insane (< 1m)
            if (delta > 0.002f && delta < 1.0f) {
                correctionTarget = bestObservedOrigin
                correctionFramesRemaining = CORRECTION_FRAMES
                android.util.Log.d("ArCoreAxes",
                    "Correction triggered: delta=${(delta*1000).toInt()}mm, lerping over $CORRECTION_FRAMES frames")
            }
        }
    }

    /**
     * Phase 3: Apply smooth correction — lerp position, slerp rotation.
     * Called every frame when a correction is active.
     */
    private fun applySmoothCorrection() {
        val target = correctionTarget ?: return
        if (correctionFramesRemaining <= 0) {
            correctionTarget = null
            return
        }

        // Lerp factor: move 1/remaining towards target each frame
        // This gives exponential ease-out behavior
        val t = 1.0f / correctionFramesRemaining.toFloat()

        // Lerp position (columns 12, 13, 14 in column-major 4x4)
        lockedOriginMatrix[12] += (target[12] - lockedOriginMatrix[12]) * t
        lockedOriginMatrix[13] += (target[13] - lockedOriginMatrix[13]) * t
        lockedOriginMatrix[14] += (target[14] - lockedOriginMatrix[14]) * t

        // Lerp rotation columns (simplified — lerp each basis vector and re-orthogonalize)
        for (col in 0..2) {
            val base = col * 4
            lockedOriginMatrix[base + 0] += (target[base + 0] - lockedOriginMatrix[base + 0]) * t
            lockedOriginMatrix[base + 1] += (target[base + 1] - lockedOriginMatrix[base + 1]) * t
            lockedOriginMatrix[base + 2] += (target[base + 2] - lockedOriginMatrix[base + 2]) * t
        }

        // Re-orthogonalize rotation part (Gram-Schmidt)
        reorthogonalize(lockedOriginMatrix)

        correctionFramesRemaining--

        if (correctionFramesRemaining <= 0) {
            // Snap to target on last frame
            System.arraycopy(target, 0, lockedOriginMatrix, 0, 16)
            correctionTarget = null
        }
    }

    /**
     * Re-orthogonalize the rotation part of a 4x4 matrix using Gram-Schmidt.
     * Ensures axes remain unit length and perpendicular after lerping.
     */
    private fun reorthogonalize(m: FloatArray) {
        // Extract columns (rotation axes)
        val x = floatArrayOf(m[0], m[1], m[2])
        val y = floatArrayOf(m[4], m[5], m[6])

        // Normalize X
        val xLen = Math.sqrt((x[0]*x[0] + x[1]*x[1] + x[2]*x[2]).toDouble()).toFloat()
        if (xLen > 0.001f) { x[0] /= xLen; x[1] /= xLen; x[2] /= xLen }

        // Y = Y - dot(Y,X)*X (make Y perpendicular to X)
        val dotYX = y[0]*x[0] + y[1]*x[1] + y[2]*x[2]
        y[0] -= dotYX * x[0]; y[1] -= dotYX * x[1]; y[2] -= dotYX * x[2]
        val yLen = Math.sqrt((y[0]*y[0] + y[1]*y[1] + y[2]*y[2]).toDouble()).toFloat()
        if (yLen > 0.001f) { y[0] /= yLen; y[1] /= yLen; y[2] /= yLen }

        // Z = cross(X, Y)
        val z = floatArrayOf(
            x[1]*y[2] - x[2]*y[1],
            x[2]*y[0] - x[0]*y[2],
            x[0]*y[1] - x[1]*y[0],
        )

        // Write back
        m[0] = x[0]; m[1] = x[1]; m[2] = x[2]
        m[4] = y[0]; m[5] = y[1]; m[6] = y[2]
        m[8] = z[0]; m[9] = z[1]; m[10] = z[2]
    }

    // ========== Multi-Anchor: Config Loading + Origin Computation ==========

    private fun loadAnchorConfig() {
        try {
            val inputStream = context.assets.open("flutter_assets/assets/qr_anchors_config.json")
            val json = inputStream.bufferedReader().readText()
            inputStream.close()

            val root = org.json.JSONObject(json)
            val anchors = root.getJSONArray("anchors")

            for (i in 0 until anchors.length()) {
                val obj = anchors.getJSONObject(i)
                val pos = obj.getJSONArray("position")
                val rot = obj.getJSONArray("rotation")

                anchorConfigs.add(QrAnchorConfig(
                    id = obj.getString("id"),
                    isPrimary = obj.getBoolean("primary"),
                    posX = pos.getDouble(0).toFloat(),
                    posY = pos.getDouble(1).toFloat(),
                    posZ = pos.getDouble(2).toFloat(),
                    rotX = rot.getDouble(0).toFloat(),
                    rotY = rot.getDouble(1).toFloat(),
                    rotZ = rot.getDouble(2).toFloat(),
                    rotW = rot.getDouble(3).toFloat(),
                    physicalSize = obj.getDouble("physicalSize").toFloat(),
                    label = obj.getString("label"),
                ))
            }
            android.util.Log.d("ArCoreAxes", "Loaded ${anchorConfigs.size} anchor configs")
        } catch (e: Exception) {
            android.util.Log.e("ArCoreAxes", "Failed to load config: ${e.message}")
            anchorConfigs.add(QrAnchorConfig("QR_ORIGIN_001", true, 0f,0f,0f, 0f,0f,0f,1f, 0.15f, "Primary"))
        }
    }

    /**
     * Given a detected QR world pose and its config, compute where origin should be.
     */
    private fun computeOriginFromQr(qrWorldMatrix: FloatArray, cfg: QrAnchorConfig): FloatArray {
        if (cfg.isPrimary) return qrWorldMatrix.clone()

        // relativeToOrigin = rotation(cfg.rot) then translate(cfg.pos)
        // This is the transform FROM origin TO this QR.
        // We need inverse: FROM this QR TO origin.
        val relMatrix = FloatArray(16)
        android.opengl.Matrix.setIdentityM(relMatrix, 0)
        android.opengl.Matrix.translateM(relMatrix, 0, cfg.posX, cfg.posY, cfg.posZ)

        val invRelMatrix = FloatArray(16)
        android.opengl.Matrix.invertM(invRelMatrix, 0, relMatrix, 0)

        val originMatrix = FloatArray(16)
        android.opengl.Matrix.multiplyMM(originMatrix, 0, qrWorldMatrix, 0, invRelMatrix, 0)
        return originMatrix
    }

    // ========== Confidence ==========

    // ========== Phase 4: Confidence + Dead Reckoning ==========

    private fun updateConfidence() {
        if (!originLocked) {
            confidenceScore = 0f
            return
        }

        frameCounter++

        val timeSinceAnchorSec = (System.currentTimeMillis() - lastAnchorObservationMs) / 1000f
        val timeSinceAnchorMs = System.currentTimeMillis() - lastAnchorObservationMs

        // Confidence decays with time and path length
        val timeDecay = Math.max(0f, 1f - timeSinceAnchorSec / 120f)
        val pathDecay = Math.max(0f, 1f - accumulatedPathLength * 0.005f)
        confidenceScore = Math.min(timeDecay, pathDecay)

        // QR visible → full confidence, reset
        if (qrVisibleThisFrame) {
            confidenceScore = 1f
            accumulatedPathLength = 0f
            if (isFrozen) {
                isFrozen = false
                glView.post { channel.invokeMethod("onDeadReckoningFreeze", false) }
            }
        }

        // Dead reckoning ceiling: freeze if no anchor for 90 seconds
        if (timeSinceAnchorMs > DEAD_RECKONING_LIMIT_MS && !isFrozen) {
            isFrozen = true
            android.util.Log.w("ArCoreAxes", "DEAD RECKONING CEILING — frozen after ${timeSinceAnchorMs/1000}s")
            glView.post { channel.invokeMethod("onDeadReckoningFreeze", true) }
        }

        // Send confidence to Flutter every 15 frames (~0.5s)
        if (frameCounter % 15 == 0) {
            val rounded = (confidenceScore * 100).toInt().toFloat() / 100f
            if (Math.abs(rounded - lastConfidenceSentToFlutter) > 0.02f) {
                lastConfidenceSentToFlutter = rounded
                glView.post {
                    channel.invokeMethod("onConfidenceUpdate", mapOf(
                        "confidence" to rounded,
                        "timeSinceAnchorSec" to timeSinceAnchorSec,
                        "pathLengthM" to accumulatedPathLength,
                        "qrVisible" to qrVisibleThisFrame,
                        "frozen" to isFrozen,
                        "trackingAnchors" to envAnchors.count { it.anchor.trackingState == TrackingState.TRACKING },
                    ))
                }
            }
        }
    }

    fun resume() {
        session?.resume()
        glView.onResume()
    }

    fun pause() {
        glView.onPause()
        session?.pause()
    }
}


/**
 * Renders 3D coordinate axes using OpenGL ES 2.0.
 */
class AxesRenderer {
    private var program = 0
    private var positionHandle = 0
    private var colorHandle = 0
    private var mvpMatrixHandle = 0
    private val axisLength = 0.10f

    fun createOnGlThread() {
        val vertexShader = """
            uniform mat4 u_MVPMatrix;
            attribute vec4 a_Position;
            void main() { gl_Position = u_MVPMatrix * a_Position; }
        """.trimIndent()
        val fragmentShader = """
            precision mediump float;
            uniform vec4 u_Color;
            void main() { gl_FragColor = u_Color; }
        """.trimIndent()

        program = createProgram(vertexShader, fragmentShader)
        positionHandle = GLES20.glGetAttribLocation(program, "a_Position")
        colorHandle = GLES20.glGetUniformLocation(program, "u_Color")
        mvpMatrixHandle = GLES20.glGetUniformLocation(program, "u_MVPMatrix")
    }

    fun draw(viewMatrix: FloatArray, projMatrix: FloatArray, modelMatrix: FloatArray) {
        GLES20.glUseProgram(program)
        GLES20.glLineWidth(8f)
        GLES20.glEnable(GLES20.GL_DEPTH_TEST)

        val mvMatrix = FloatArray(16)
        val mvpMatrix = FloatArray(16)
        android.opengl.Matrix.multiplyMM(mvMatrix, 0, viewMatrix, 0, modelMatrix, 0)
        android.opengl.Matrix.multiplyMM(mvpMatrix, 0, projMatrix, 0, mvMatrix, 0)
        GLES20.glUniformMatrix4fv(mvpMatrixHandle, 1, false, mvpMatrix, 0)

        drawLine(floatArrayOf(0f, 0f, 0f, axisLength, 0f, 0f), floatArrayOf(1f, 0f, 0f, 1f))
        drawLine(floatArrayOf(0f, 0f, 0f, 0f, axisLength, 0f), floatArrayOf(0f, 1f, 0f, 1f))
        drawLine(floatArrayOf(0f, 0f, 0f, 0f, 0f, axisLength), floatArrayOf(0f, 0f, 1f, 1f))
        drawLine(floatArrayOf(-0.003f, 0f, 0f, 0.003f, 0f, 0f), floatArrayOf(1f, 1f, 1f, 1f))
        drawLine(floatArrayOf(0f, -0.003f, 0f, 0f, 0.003f, 0f), floatArrayOf(1f, 1f, 1f, 1f))
        drawLine(floatArrayOf(0f, 0f, -0.003f, 0f, 0f, 0.003f), floatArrayOf(1f, 1f, 1f, 1f))
    }

    fun drawSphere(viewMatrix: FloatArray, projMatrix: FloatArray, modelMatrix: FloatArray, color: FloatArray, radius: Float) {
        GLES20.glUseProgram(program)
        GLES20.glEnable(GLES20.GL_DEPTH_TEST)

        val mvMatrix = FloatArray(16)
        val mvpMatrix = FloatArray(16)
        android.opengl.Matrix.multiplyMM(mvMatrix, 0, viewMatrix, 0, modelMatrix, 0)
        android.opengl.Matrix.multiplyMM(mvpMatrix, 0, projMatrix, 0, mvMatrix, 0)
        GLES20.glUniformMatrix4fv(mvpMatrixHandle, 1, false, mvpMatrix, 0)
        GLES20.glUniform4fv(colorHandle, 1, color, 0)

        // Generate solid sphere using triangle strips (latitude/longitude)
        val stacks = 10
        val slices = 12
        val r = radius

        for (i in 0 until stacks) {
            val lat0 = Math.PI * (-0.5 + i.toDouble() / stacks)
            val lat1 = Math.PI * (-0.5 + (i + 1).toDouble() / stacks)
            val y0 = (r * Math.sin(lat0)).toFloat()
            val y1 = (r * Math.sin(lat1)).toFloat()
            val r0 = (r * Math.cos(lat0)).toFloat()
            val r1 = (r * Math.cos(lat1)).toFloat()

            val verts = FloatArray((slices + 1) * 2 * 3)
            for (j in 0..slices) {
                val lng = 2.0 * Math.PI * j.toDouble() / slices
                val x = Math.cos(lng).toFloat()
                val z = Math.sin(lng).toFloat()
                val idx = j * 6
                verts[idx] = r1 * x; verts[idx + 1] = y1; verts[idx + 2] = r1 * z
                verts[idx + 3] = r0 * x; verts[idx + 4] = y0; verts[idx + 5] = r0 * z
            }

            val buffer = ByteBuffer.allocateDirect(verts.size * 4)
                .order(ByteOrder.nativeOrder()).asFloatBuffer().put(verts)
            buffer.position(0)
            GLES20.glVertexAttribPointer(positionHandle, 3, GLES20.GL_FLOAT, false, 0, buffer)
            GLES20.glEnableVertexAttribArray(positionHandle)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, (slices + 1) * 2)
        }
    }

    private fun drawLine(vertices: FloatArray, color: FloatArray) {
        val buffer = ByteBuffer.allocateDirect(vertices.size * 4)
            .order(ByteOrder.nativeOrder()).asFloatBuffer().put(vertices)
        buffer.position(0)
        GLES20.glVertexAttribPointer(positionHandle, 3, GLES20.GL_FLOAT, false, 0, buffer)
        GLES20.glEnableVertexAttribArray(positionHandle)
        GLES20.glUniform4fv(colorHandle, 1, color, 0)
        GLES20.glDrawArrays(GLES20.GL_LINES, 0, vertices.size / 3)
    }

    private fun createProgram(vs: String, fs: String): Int {
        val v = loadShader(GLES20.GL_VERTEX_SHADER, vs)
        val f = loadShader(GLES20.GL_FRAGMENT_SHADER, fs)
        val p = GLES20.glCreateProgram()
        GLES20.glAttachShader(p, v); GLES20.glAttachShader(p, f); GLES20.glLinkProgram(p)
        return p
    }

    private fun loadShader(type: Int, source: String): Int {
        val s = GLES20.glCreateShader(type)
        GLES20.glShaderSource(s, source); GLES20.glCompileShader(s)
        return s
    }
}

/**
 * Renders the camera background texture.
 */
class BackgroundRenderer {
    var textureId = 0; private set
    private var program = 0
    private var positionHandle = 0
    private var texCoordHandle = 0
    private val QUAD_COORDS = floatArrayOf(-1f, -1f, -1f, 1f, 1f, -1f, 1f, 1f)
    private val QUAD_TEXCOORDS = floatArrayOf(0f, 1f, 0f, 0f, 1f, 1f, 1f, 0f)
    private lateinit var quadVertices: FloatBuffer
    private lateinit var quadTexCoords: FloatBuffer

    fun createOnGlThread(context: Context) {
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        textureId = textures[0]
        GLES20.glBindTexture(0x8D65, textureId)
        GLES20.glTexParameteri(0x8D65, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(0x8D65, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(0x8D65, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(0x8D65, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)

        val vs = "attribute vec4 a_Position; attribute vec2 a_TexCoord; varying vec2 v_TexCoord; void main() { gl_Position = a_Position; v_TexCoord = a_TexCoord; }"
        val fs = "#extension GL_OES_EGL_image_external : require\nprecision mediump float; varying vec2 v_TexCoord; uniform samplerExternalOES u_Texture; void main() { gl_FragColor = texture2D(u_Texture, v_TexCoord); }"

        program = createProgram(vs, fs)
        positionHandle = GLES20.glGetAttribLocation(program, "a_Position")
        texCoordHandle = GLES20.glGetAttribLocation(program, "a_TexCoord")
        quadVertices = ByteBuffer.allocateDirect(QUAD_COORDS.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().put(QUAD_COORDS); quadVertices.position(0)
        quadTexCoords = ByteBuffer.allocateDirect(QUAD_TEXCOORDS.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().put(QUAD_TEXCOORDS); quadTexCoords.position(0)
    }

    fun draw(frame: Frame) {
        if (frame.hasDisplayGeometryChanged()) { frame.transformDisplayUvCoords(quadTexCoords, quadTexCoords) }
        GLES20.glDisable(GLES20.GL_DEPTH_TEST); GLES20.glDepthMask(false); GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0); GLES20.glBindTexture(0x8D65, textureId)
        GLES20.glVertexAttribPointer(positionHandle, 2, GLES20.GL_FLOAT, false, 0, quadVertices)
        GLES20.glVertexAttribPointer(texCoordHandle, 2, GLES20.GL_FLOAT, false, 0, quadTexCoords)
        GLES20.glEnableVertexAttribArray(positionHandle); GLES20.glEnableVertexAttribArray(texCoordHandle)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDepthMask(true); GLES20.glEnable(GLES20.GL_DEPTH_TEST)
    }

    private fun createProgram(vs: String, fs: String): Int {
        val v = loadShader(GLES20.GL_VERTEX_SHADER, vs); val f = loadShader(GLES20.GL_FRAGMENT_SHADER, fs)
        val p = GLES20.glCreateProgram(); GLES20.glAttachShader(p, v); GLES20.glAttachShader(p, f); GLES20.glLinkProgram(p); return p
    }

    private fun loadShader(type: Int, source: String): Int {
        val s = GLES20.glCreateShader(type); GLES20.glShaderSource(s, source); GLES20.glCompileShader(s); return s
    }
}

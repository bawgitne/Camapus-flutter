package com.qrorigin

import android.app.Activity
import android.content.Context
import com.google.ar.core.*
import com.google.ar.core.exceptions.*
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Flutter plugin that bridges ARCore image tracking to Dart.
 *
 * Responsibilities:
 * - Manage ARCore Session lifecycle
 * - Configure augmented image database with QR reference
 * - Stream per-frame pose data + gravity vector to Dart via EventChannel
 * - Compute angle score (dot product) on native side for efficiency
 */
class ArPlugin : FlutterPlugin, MethodCallHandler, ActivityAware {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null

    private var activity: Activity? = null
    private var session: Session? = null
    private var isRunning = AtomicBoolean(false)

    private var qrPhysicalSize: Float = 0.15f // meters

    // --- FlutterPlugin ---

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel = MethodChannel(binding.binaryMessenger, "qr_origin/ar_method")
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, "qr_origin/ar_events")
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }
            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
    }

    // --- MethodCallHandler ---

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> {
                qrPhysicalSize = (call.argument<Double>("qrPhysicalSize") ?: 0.15).toFloat()
                initializeArSession(result)
            }
            "pause" -> {
                session?.pause()
                isRunning.set(false)
                result.success(null)
            }
            "resume" -> {
                session?.resume()
                isRunning.set(true)
                result.success(null)
            }
            "dispose" -> {
                session?.close()
                session = null
                isRunning.set(false)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // --- AR Session ---

    private fun initializeArSession(result: MethodChannel.Result) {
        val act = activity ?: run {
            result.error("NO_ACTIVITY", "Activity not available", null)
            return
        }

        try {
            // Check ARCore availability
            val availability = ArCoreApk.getInstance().checkAvailability(act)
            if (availability.isTransient) {
                // Retry after a short delay in production
                result.error("AR_UNAVAILABLE", "ARCore is checking availability", null)
                return
            }
            if (!availability.isSupported) {
                result.error("AR_UNSUPPORTED", "ARCore not supported on this device", null)
                return
            }

            session = Session(act).also { sess ->
                // Configure for image tracking
                val config = Config(sess).apply {
                    updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
                    focusMode = Config.FocusMode.AUTO
                    planeFindingMode = Config.PlaneFindingMode.DISABLED // We don't need planes
                }

                // Setup augmented image database
                // In production, load the QR reference image from assets
                val imageDatabase = AugmentedImageDatabase(sess)
                // imageDatabase.addImage("qr_reference", bitmap, qrPhysicalSize)
                config.augmentedImageDatabase = imageDatabase

                sess.configure(config)
                sess.resume()
            }

            isRunning.set(true)
            startFrameLoop()
            result.success(true)

        } catch (e: UnavailableException) {
            result.error("AR_ERROR", "ARCore error: ${e.message}", null)
        }
    }

    /**
     * Main frame processing loop.
     * In production, this runs on a dedicated thread or uses ARCore's callback.
     * Here we show the logic that would execute per-frame.
     */
    private fun startFrameLoop() {
        // NOTE: In a real implementation, this would be driven by
        // a GLSurfaceView.Renderer's onDrawFrame or a dedicated handler.
        // For the Flutter plugin pattern, we'd use a Handler posting at 30fps.
        //
        // Pseudocode for the per-frame logic:
        // handler.post(frameRunnable)
    }

    /**
     * Process a single AR frame. Called ~30fps.
     * Extracts QR pose, gravity, and angle score.
     */
    fun processFrame(frame: Frame) {
        if (!isRunning.get()) return

        // Get gravity from the Android sensor pose
        val cameraPose = frame.camera.pose
        // Camera's -Z axis is the forward direction
        val cameraForward = floatArrayOf(
            -cameraPose.zAxis[0],
            -cameraPose.zAxis[1],
            -cameraPose.zAxis[2]
        )

        // Get gravity vector (world Y-axis in ARCore is always up)
        // So gravity = (0, -1, 0) in ARCore world coordinates
        sendGravityEvent(floatArrayOf(0f, -9.81f, 0f))

        // Check augmented images
        val updatedImages = frame.getUpdatedTrackables(AugmentedImage::class.java)
        for (image in updatedImages) {
            if (image.trackingState == TrackingState.TRACKING) {
                val pose = image.centerPose

                // QR normal is the Z-axis of the image pose
                val qrNormal = pose.zAxis

                // Compute angle score: |dot(cameraForward, qrNormal)|
                val dot = Math.abs(
                    cameraForward[0] * qrNormal[0] +
                    cameraForward[1] * qrNormal[1] +
                    cameraForward[2] * qrNormal[2]
                )

                // Compute reprojection error estimate
                // ARCore doesn't directly expose this, so we estimate from
                // tracking method quality. Use image extent ratio as proxy.
                val extentX = image.extentX
                val extentZ = image.extentZ
                val expectedSize = qrPhysicalSize
                val sizeError = Math.abs(extentX - expectedSize) / expectedSize * 10f

                sendPoseFrameEvent(
                    position = floatArrayOf(
                        pose.tx(), pose.ty(), pose.tz()
                    ),
                    quaternion = floatArrayOf(
                        pose.qx(), pose.qy(), pose.qz(), pose.qw()
                    ),
                    reprojectionError = sizeError.toDouble(),
                    angleScore = dot.toDouble(),
                    timestampMs = System.currentTimeMillis()
                )

                // Send QR ID
                sendQrDetectedEvent(image.name ?: "qr_${image.index}")
            }
        }
    }

    // --- Event Senders ---

    private fun sendPoseFrameEvent(
        position: FloatArray,
        quaternion: FloatArray,
        reprojectionError: Double,
        angleScore: Double,
        timestampMs: Long
    ) {
        val data = mapOf(
            "position" to position.map { it.toDouble() },
            "quaternion" to quaternion.map { it.toDouble() },
            "reprojectionError" to reprojectionError,
            "angleScore" to angleScore,
            "timestampMs" to timestampMs
        )
        activity?.runOnUiThread {
            eventSink?.success(mapOf("type" to "poseFrame", "data" to data))
        }
    }

    private fun sendGravityEvent(gravity: FloatArray) {
        activity?.runOnUiThread {
            eventSink?.success(mapOf(
                "type" to "gravity",
                "data" to gravity.map { it.toDouble() }
            ))
        }
    }

    private fun sendQrDetectedEvent(qrId: String) {
        activity?.runOnUiThread {
            eventSink?.success(mapOf("type" to "qrDetected", "data" to qrId))
        }
    }

    // --- ActivityAware ---

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }
}

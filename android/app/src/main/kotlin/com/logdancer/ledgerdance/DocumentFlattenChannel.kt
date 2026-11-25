package com.logdancer.ledgerdance

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OnnxJavaType
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.res.AssetManager
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.FloatBuffer

internal fun registerDocumentFlatten(
    messenger: BinaryMessenger, assets: AssetManager, loader: FlutterLoader
) {
    val channel = MethodChannel(
        messenger, "com.tntlikely.beecount/document_flatten", StandardMethodCodec.INSTANCE,
        messenger.makeBackgroundTaskQueue()
    )
    channel.setMethodCallHandler { call, result ->
        if (call.method != "flatten") {
            result.notImplemented()
            return@setMethodCallHandler
        }
        val width = call.argument<Int>("width")
        val height = call.argument<Int>("height")
        val pixels = call.argument<FloatArray>("pixels")
        if (width == null || height == null || width !in 64..1920 ||
            height !in 64..1920 || pixels?.size != width * height * 3
        ) {
            result.error("INVALID_IMAGE", "Invalid UVDoc tensor dimensions", null)
            return@setMethodCallHandler
        }
        try {
            val model = assets.open(loader.getLookupKeyForAsset("assets/models/uvdoc.onnx"))
                .use { it.readBytes() }
            val env = OrtEnvironment.getEnvironment()
            val shape = longArrayOf(1, 3, height.toLong(), width.toLong())
            val flattened = OrtSession.SessionOptions().use { options ->
                options.setIntraOpNumThreads(2)
                options.setInterOpNumThreads(1)
                env.createSession(model, options).use { session ->
                    OnnxTensor.createTensor(env, FloatBuffer.wrap(pixels), shape).use { input ->
                        session.run(mapOf("image" to input)).use { outputs ->
                            val output = outputs[0] as OnnxTensor
                            check(output.info.type == OnnxJavaType.FLOAT &&
                                output.info.shape.contentEquals(shape))
                            FloatArray(pixels.size).also { output.floatBuffer.get(it) }
                        }
                    }
                }
            }
            result.success(flattened)
        } catch (error: Exception) {
            result.error("FLATTEN_FAILED", error.javaClass.simpleName, null)
        } catch (error: LinkageError) {
            result.error("FLATTEN_UNAVAILABLE", error.javaClass.simpleName, null)
        }
    }
}

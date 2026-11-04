/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

package frauddetection

import org.apache.kafka.clients.consumer.ConsumerConfig.*
import org.apache.kafka.clients.consumer.KafkaConsumer
import org.apache.kafka.common.serialization.ByteArrayDeserializer
import org.apache.kafka.common.serialization.StringDeserializer
import org.apache.logging.log4j.LogManager
import org.apache.logging.log4j.Logger
import oteldemo.Demo.*
import java.time.Duration
import java.time.Duration.ofMillis
import java.time.Instant
import java.util.*
import kotlin.math.sqrt
import kotlin.system.exitProcess
import dev.openfeature.contrib.providers.flagd.FlagdOptions
import dev.openfeature.contrib.providers.flagd.FlagdProvider
import dev.openfeature.sdk.Client
import dev.openfeature.sdk.EvaluationContext
import dev.openfeature.sdk.ImmutableContext
import dev.openfeature.sdk.Value
import dev.openfeature.sdk.OpenFeatureAPI

val topic: String = System.getenv("KAFKA_TOPIC") ?: "orders"
const val groupID = "fraud-detection"

private val logger: Logger = LogManager.getLogger(groupID)

// Velocity check: each order is scored against the feature vectors of past orders,
// so a burst of near-identical orders (card testing) stands out. History older
// than FRAUD_HISTORY_WINDOW (ISO-8601 duration, e.g. PT24H) is dropped; when it
// is unset every order is kept.
const val featureDims = 512
val historyWindow: Duration? = System.getenv("FRAUD_HISTORY_WINDOW")?.takeIf { it.isNotBlank() }?.let(Duration::parse)

class PastOrder(val at: Instant, val features: DoubleArray)

val history = java.util.ArrayDeque<PastOrder>()

fun main() {
    val options = FlagdOptions.builder()
    .withGlobalTelemetry(true)
    .build()
    val flagdProvider = FlagdProvider(options)
    OpenFeatureAPI.getInstance().setProvider(flagdProvider)

    val props = Properties()
    props[KEY_DESERIALIZER_CLASS_CONFIG] = StringDeserializer::class.java.name
    props[VALUE_DESERIALIZER_CLASS_CONFIG] = ByteArrayDeserializer::class.java.name
    props[GROUP_ID_CONFIG] = groupID
    // Read from the start of the topic so a freshly-joined consumer group still
    // processes orders produced before it finished joining, matching the
    // accounting consumer's behaviour. Without this the Kafka default of
    // "latest" silently drops those orders, so fraud-detection may emit no
    // telemetry on a quiet/cold start.
    props[AUTO_OFFSET_RESET_CONFIG] = "earliest"
    val bootstrapServers = System.getenv("KAFKA_ADDR")
    if (bootstrapServers == null) {
        println("KAFKA_ADDR is not supplied")
        exitProcess(1)
    }
    props[BOOTSTRAP_SERVERS_CONFIG] = bootstrapServers
    val consumer = KafkaConsumer<String, ByteArray>(props).apply {
        subscribe(listOf(topic))
    }

    var totalCount = 0L

    consumer.use {
        while (true) {
            totalCount = consumer
                .poll(ofMillis(100))
                .fold(totalCount) { accumulator, record ->
                    val newCount = accumulator + 1
                    if (getFeatureFlagValue("kafkaQueueProblems") > 0) {
                        logger.info("FeatureFlag 'kafkaQueueProblems' is enabled, sleeping 1 second")
                        Thread.sleep(1000)
                    }
                    val orders = OrderResult.parseFrom(record.value())
                    val similarity = maxSimilarity(features(orders), Instant.now())
                    logger.info("Consumed record with orderId: ${orders.orderId}, and updated total count to: $newCount, max similarity to past orders: ${"%.3f".format(similarity)} over ${history.size} orders")
                    newCount
                }
        }
    }
}

fun features(order: OrderResult): DoubleArray {
    val v = DoubleArray(featureDims)
    fun add(key: String, weight: Double) {
        val h = key.hashCode()
        v[Math.floorMod(h, featureDims)] += if (h and 1 == 0) weight else -weight
    }
    order.itemsList.forEach { add("item:${it.item.productId}", it.item.quantity.toDouble()) }
    with(order.shippingAddress) {
        add("street:$streetAddress", 1.0)
        add("city:$city", 1.0)
        add("zip:$zipCode", 1.0)
        add("country:$country", 1.0)
    }
    add("shipping:${order.shippingCost.units / 10}", 1.0)
    val norm = sqrt(v.sumOf { it * it })
    if (norm > 0) for (i in v.indices) v[i] /= norm
    return v
}

fun maxSimilarity(v: DoubleArray, now: Instant): Double {
    historyWindow?.let { w -> while (history.isNotEmpty() && history.peekFirst().at < now - w) history.removeFirst() }
    var best = 0.0
    for (past in history) {
        var dot = 0.0
        for (i in 0 until featureDims) dot += v[i] * past.features[i]
        if (dot > best) best = dot
    }
    history.addLast(PastOrder(now, v))
    return best
}

/**
* Retrieves the status of a feature flag from the Feature Flag service.
*
* @param ff The name of the feature flag to retrieve.
* @return `true` if the feature flag is enabled, `false` otherwise or in case of errors.
*/
fun getFeatureFlagValue(ff: String): Int {
    val client = OpenFeatureAPI.getInstance().client
    // TODO: Plumb the actual session ID from the frontend via baggage?
    val uuid = UUID.randomUUID()

    val clientAttrs = mutableMapOf<String, Value>()
    clientAttrs["session"] = Value(uuid.toString())
    client.evaluationContext = ImmutableContext(clientAttrs)
    val intValue = client.getIntegerValue(ff, 0)
    return intValue
}

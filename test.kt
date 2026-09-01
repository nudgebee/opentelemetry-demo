import dev.openfeature.contrib.providers.flagd.FlagdOptions
import java.lang.reflect.Method

fun main() {
    val methods = FlagdOptions.Builder::class.java.methods
    for (m in methods) {
        println(m.name)
    }
}

import dev.openfeature.contrib.providers.flagd.FlagdOptions;
import java.lang.reflect.Method;

public class Test {
    public static void main(String[] args) {
        for (Method m : FlagdOptions.Builder.class.getMethods()) {
            System.out.println(m.getName());
        }
    }
}

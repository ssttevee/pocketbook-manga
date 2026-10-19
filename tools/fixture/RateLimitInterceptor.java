// Fixture mirrors the inspected Keiyoushi rate-rule shape and encoded Duration.
package keiyoushi.network;
import java.util.List;
import kotlin.jvm.functions.Function1;
import okhttp3.*;
public final class RateLimitInterceptor implements Interceptor {
  private static final class RateLimit {
    private final int permits=3;
    private final long period=200000000L; // 100 ms in Kotlin Duration's nanosecond representation
    private final long interval=40000000L; // 20 ms
    private final Function1<HttpUrl,Boolean> shouldLimit = url -> true;
  }
  private final List<RateLimit> rateLimits=List.of(new RateLimit());
  public Response intercept(Chain chain) throws java.io.IOException { return chain.proceed(chain.request()); }
}
